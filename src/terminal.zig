const std = @import("std");
const c = @import("c.zig").c;
const wire = @import("wire.zig");
const A = std.mem.Allocator;
const List = std.ArrayList(u8);

pub const Style = struct {
    fg: u32 = 0,
    bg: u32 = 0,
    flags: u8 = 0,
    fn emit(self: Style, out: *List, a: A) !void {
        try out.appendSlice(a, "\x1b[0");
        for ([_]u8{ 1, 2, 3, 4, 5, 7, 8, 9 }, 0..) |code, i| {
            if (self.flags & (@as(u8, 1) << @intCast(i)) != 0) try fmt(out, a, ";{d}", .{code});
        }
        for ([_]u32{ self.fg, self.bg }, 0..) |color, i| {
            const base: u8 = if (i == 0) 38 else 48;
            if (color & 0x1000000 != 0) try fmt(out, a, ";{d};2;{d};{d};{d}", .{ base, (color >> 16) & 255, (color >> 8) & 255, color & 255 }) else if (color != 0) try fmt(out, a, ";{d};5;{d}", .{ base, color - 1 });
        }
        try out.append(a, 'm');
    }
};
pub const Cell = struct {
    text: [24]u8 = @splat(0),
    len: u8 = 0,
    width: u8 = 1,
    style: Style = .{},
};
pub const Screen = struct {
    cells: []Cell,
    width: usize,
    height: usize,
    x: usize = 0,
    y: usize = 0,
    top: usize = 0,
    bottom: usize,
    style: Style = .{},
    visible: bool = true,
    wrap: bool = false,
    modes: u16 = 0,
    parser: enum { ground, esc, csi, osc, osc_esc, charset } = .ground,
    sequence: [4096]u8 = undefined,
    sequence_len: usize = 0,
    utf8: [4]u8 = undefined,
    utf8_len: u3 = 0,
    utf8_need: u3 = 0,
    pub fn init(a: A, w: usize, h: usize) !Screen {
        if (w == 0 or h == 0 or w > 1000 or h > 500) return error.InvalidTerminalSize;
        const cells = try a.alloc(Cell, w * h);
        @memset(cells, .{});
        return .{ .cells = cells, .width = w, .height = h, .bottom = h - 1 };
    }
    pub fn deinit(self: *Screen, a: A) void {
        a.free(self.cells);
    }
    pub fn clone(self: Screen, a: A) !Screen {
        var result = self;
        result.cells = try a.dupe(Cell, self.cells);
        return result;
    }
    pub fn resize(self: *Screen, a: A, w: usize, h: usize) !void {
        if (w == self.width and h == self.height) return;
        var next = try Screen.init(a, w, h);
        for (0..@min(h, self.height)) |y| {
            @memcpy(next.cells[y * w ..][0..@min(w, self.width)], self.cells[y * self.width ..][0..@min(w, self.width)]);
        }
        next.x = @min(self.x, w - 1);
        next.y = @min(self.y, h - 1);
        next.style = self.style;
        next.visible = self.visible;
        next.modes = self.modes;
        self.deinit(a);
        self.* = next;
    }
    pub fn apply(self: *Screen, a: A, diff: []const u8) !void {
        var message: wire.Reader = .{ .data = diff };
        while (try message.next()) |instruction| {
            if (instruction.tag != 1 or instruction.kind != 2) continue;
            var extensions: wire.Reader = .{ .data = instruction.data };
            while (try extensions.next()) |ext| {
                if (ext.kind != 2) continue;
                var body: wire.Reader = .{ .data = ext.data };
                var w = self.width;
                var h = self.height;
                while (try body.next()) |f| {
                    if (ext.tag == 2 and f.tag == 4 and f.kind == 2) self.feed(f.data);
                    if (ext.tag == 3 and f.kind == 0) {
                        if (f.tag == 5) w = @intCast(@min(1001, f.integer));
                        if (f.tag == 6) h = @intCast(@min(501, f.integer));
                    }
                }
                if (ext.tag == 3) try self.resize(a, w, h);
            }
        }
    }
    pub fn render(self: Screen, a: A, previous: ?Screen) ![]u8 {
        var out: List = .empty;
        errdefer out.deinit(a);
        const same_size = if (previous) |p| p.width == self.width and p.height == self.height else false;
        // Mosh's server translates SS3 arrow keys for the remote application's
        // cursor mode. The physical client must always use application mode.
        try out.appendSlice(a, "\x1b[?1h\x1b[?25l");
        if (!same_size) try out.appendSlice(a, "\x1b[0m\x1b[r\x1b[H\x1b[2J");
        var style: ?Style = null;
        for (0..self.height) |y| {
            var x: usize = 0;
            var positioned = false;
            while (x < self.width) : (x += 1) {
                const index = y * self.width + x;
                const cell = self.cells[index];
                if (cell.width == 0) continue;
                if (same_size and std.meta.eql(cell, previous.?.cells[index])) {
                    positioned = false;
                    continue;
                }
                if (!positioned) try fmt(&out, a, "\x1b[{d};{d}H", .{ y + 1, x + 1 });
                if (style == null or !std.meta.eql(style.?, cell.style)) {
                    try cell.style.emit(&out, a);
                    style = cell.style;
                }
                try out.appendSlice(a, if (cell.len == 0) " " else cell.text[0..cell.len]);
                positioned = true;
            }
        }
        try fmt(&out, a, "\x1b[{d};{d}H", .{ self.y + 1, self.x + 1 });
        try self.style.emit(&out, a);
        for (mode_ids, 0..) |id, i| try fmt(&out, a, "\x1b[?{d}{c}", .{ id, @as(u8, if (self.modes & (@as(u16, 1) << @intCast(i)) != 0) 'h' else 'l') });
        if (self.visible) try out.appendSlice(a, "\x1b[?25h");
        return out.toOwnedSlice(a);
    }
    pub fn feed(self: *Screen, data: []const u8) void {
        for (data) |b| switch (self.parser) {
            .ground => {
                if (self.utf8_need > 0) {
                    if (b & 0xc0 != 0x80) {
                        self.utf8_need = 0;
                        self.utf8_len = 0;
                        continue;
                    }
                    self.utf8[self.utf8_len] = b;
                    self.utf8_len += 1;
                    if (self.utf8_len == self.utf8_need) {
                        self.put(self.utf8[0..self.utf8_len]);
                        self.utf8_need = 0;
                    }
                } else switch (b) {
                    27 => self.parser = .esc,
                    13 => {
                        self.x = 0;
                        self.wrap = false;
                    },
                    10, 11, 12 => self.linefeed(),
                    8 => {
                        self.x -|= 1;
                        self.wrap = false;
                    },
                    9 => {
                        self.x = @min((self.x / 8 + 1) * 8, self.width - 1);
                        self.wrap = false;
                    },
                    32...126 => self.put(&.{b}),
                    128...255 => {
                        self.utf8_need = std.unicode.utf8ByteSequenceLength(b) catch 0;
                        self.utf8_len = 1;
                        self.utf8[0] = b;
                    },
                    else => {},
                }
            },
            .esc => {
                self.parser = .ground;
                switch (b) {
                    '[' => {
                        self.parser = .csi;
                        self.sequence_len = 0;
                    },
                    ']' => self.parser = .osc,
                    '(', ')' => self.parser = .charset,
                    'D' => self.linefeed(),
                    'E' => {
                        self.x = 0;
                        self.linefeed();
                    },
                    else => {},
                }
            },
            .csi => {
                if (b >= 0x40 and b <= 0x7e) {
                    self.csi(b);
                    self.parser = .ground;
                } else if (self.sequence_len < self.sequence.len) {
                    self.sequence[self.sequence_len] = b;
                    self.sequence_len += 1;
                } else self.parser = .ground;
            },
            .osc => {
                if (b == 7) self.parser = .ground else if (b == 27) self.parser = .osc_esc;
            },
            .osc_esc => {
                self.parser = if (b == '\\') .ground else .osc;
            },
            .charset => self.parser = .ground,
        };
    }
    fn csi(self: *Screen, final: u8) void {
        var p: [32]usize = @splat(0);
        var count: usize = 1;
        var private = false;
        for (self.sequence[0..self.sequence_len]) |b| {
            if (b == '?') {
                private = true;
            } else if (b >= '0' and b <= '9') {
                p[count - 1] = @min(100000, p[count - 1] * 10 + b - '0');
            } else if (b == ';' and count < p.len) count += 1;
        }
        const n = @max(1, p[0]);
        switch (final) {
            'H', 'f' => {
                self.y = @min(n - 1, self.height - 1);
                self.x = @min(@max(1, p[1]) - 1, self.width - 1);
            },
            'A' => self.y -|= n,
            'B' => self.y = @min(self.y + n, self.height - 1),
            'C' => self.x = @min(self.x + n, self.width - 1),
            'D' => self.x -|= n,
            'G' => self.x = @min(n - 1, self.width - 1),
            'd' => self.y = @min(n - 1, self.height - 1),
            'm' => self.sgr(p[0..count]),
            else => self.csiExtra(final, p[0..count], private),
        }
        if (final != 'm' and final != 'h' and final != 'l') self.wrap = false;
    }
    fn csiExtra(self: *Screen, final: u8, p: []const usize, private: bool) void {
        const pos = self.y * self.width + self.x;
        switch (final) {
            'J' => switch (p[0]) {
                0 => @memset(self.cells[pos..], self.blank()),
                1 => @memset(self.cells[0 .. pos + 1], self.blank()),
                2, 3 => @memset(self.cells, self.blank()),
                else => {},
            },
            'K' => switch (p[0]) {
                0 => @memset(self.cells[pos .. (self.y + 1) * self.width], self.blank()),
                1 => @memset(self.cells[self.y * self.width .. pos + 1], self.blank()),
                2 => @memset(self.cells[self.y * self.width .. (self.y + 1) * self.width], self.blank()),
                else => {},
            },
            'X' => @memset(self.cells[pos..][0..@min(@max(1, p[0]), self.width - self.x)], self.blank()),
            'r' => {
                self.top = @min(@max(1, p[0]) - 1, self.height - 1);
                self.bottom = if (p.len > 1 and p[1] > 0) @min(p[1] - 1, self.height - 1) else self.height - 1;
                if (self.top >= self.bottom) {
                    self.top = 0;
                    self.bottom = self.height - 1;
                }
                self.x = 0;
                self.y = 0;
            },
            'h', 'l' => if (private) {
                for (p) |mode| {
                    if (mode == 25) self.visible = final == 'h';
                    for (mode_ids, 0..) |id, i| if (mode == id) {
                        const bit = @as(u16, 1) << @intCast(i);
                        if (final == 'h') self.modes |= bit else self.modes &= ~bit;
                    };
                }
            },
            else => {},
        }
    }
    fn sgr(self: *Screen, p: []const usize) void {
        var i: usize = 0;
        while (i < p.len) : (i += 1) switch (p[i]) {
            0 => self.style = .{},
            1...5 => self.style.flags |= @as(u8, 1) << @intCast(p[i] - 1),
            7...9 => self.style.flags |= @as(u8, 1) << @intCast(p[i] - 2),
            22 => self.style.flags &= ~@as(u8, 3),
            23...25 => self.style.flags &= ~(@as(u8, 1) << @intCast(p[i] - 21)),
            27...29 => self.style.flags &= ~(@as(u8, 1) << @intCast(p[i] - 22)),
            30...37 => self.style.fg = @intCast(p[i] - 29),
            40...47 => self.style.bg = @intCast(p[i] - 39),
            90...97 => self.style.fg = @intCast(p[i] - 81),
            100...107 => self.style.bg = @intCast(p[i] - 91),
            39 => self.style.fg = 0,
            49 => self.style.bg = 0,
            38, 48 => {
                const color = if (p[i] == 38) &self.style.fg else &self.style.bg;
                if (i + 2 < p.len and p[i + 1] == 5) {
                    color.* = @intCast(@min(255, p[i + 2]) + 1);
                    i += 2;
                } else if (i + 4 < p.len and p[i + 1] == 2) {
                    color.* = 0x1000000 | (@as(u32, @intCast(@min(255, p[i + 2]))) << 16) | (@as(u32, @intCast(@min(255, p[i + 3]))) << 8) | @as(u32, @intCast(@min(255, p[i + 4])));
                    i += 4;
                }
            },
            else => {},
        };
    }
    fn blank(self: Screen) Cell {
        return .{ .style = .{ .bg = self.style.bg } };
    }
    fn linefeed(self: *Screen) void {
        self.wrap = false;
        if (self.y == self.bottom) {
            const start = self.top * self.width;
            const end = (self.bottom + 1) * self.width;
            std.mem.copyForwards(Cell, self.cells[start .. end - self.width], self.cells[start + self.width .. end]);
            @memset(self.cells[end - self.width .. end], self.blank());
        } else self.y = @min(self.y + 1, self.height - 1);
    }
    fn put(self: *Screen, text: []const u8) void {
        const cp = std.unicode.utf8Decode(text) catch 0xfffd;
        const cw = c.wcwidth(@intCast(cp));
        if (cw == 0) {
            var pos = self.y * self.width + self.x;
            if (!self.wrap and pos > 0) pos -= 1;
            if (self.cells[pos].width == 0 and pos > 0) pos -= 1;
            const cell = &self.cells[pos];
            if (cell.len + text.len <= cell.text.len) {
                @memcpy(cell.text[cell.len..][0..text.len], text);
                cell.len += @intCast(text.len);
            }
            return;
        }
        const w: usize = if (cw == 2 and self.width > 1) 2 else 1;
        if (self.wrap or self.x + w > self.width) {
            self.x = 0;
            self.linefeed();
        }
        var cell: Cell = .{ .style = self.style, .width = @intCast(w), .len = @intCast(text.len) };
        @memcpy(cell.text[0..text.len], text);
        self.cells[self.y * self.width + self.x] = cell;
        if (w == 2) self.cells[self.y * self.width + self.x + 1] = .{ .width = 0, .style = self.style };
        self.x += w;
        if (self.x >= self.width) {
            self.x = self.width - 1;
            self.wrap = true;
        }
    }
};
const mode_ids = [_]usize{ 5, 1000, 1001, 1002, 1003, 1004, 1005, 1006, 1015, 2004 };
fn fmt(out: *List, a: A, comptime format: []const u8, args: anytype) !void {
    var buf: [128]u8 = undefined;
    try out.appendSlice(a, try std.fmt.bufPrint(&buf, format, args));
}

test "snapshots branch from an older state without replaying scrolls" {
    const a = std.testing.allocator;
    var initial = try Screen.init(a, 8, 3);
    defer initial.deinit(a);
    initial.feed("one\r\ntwo\r\nthree");
    var first = try initial.clone(a);
    defer first.deinit(a);
    first.feed("\r\nfour");
    var second = try initial.clone(a);
    defer second.deinit(a);
    second.feed("\r\nfive");
    try std.testing.expectEqual(@as(u8, 't'), first.cells[0].text[0]);
    try std.testing.expectEqual(@as(u8, 't'), second.cells[0].text[0]);
    try std.testing.expectEqual(@as(u8, 'i'), second.cells[17].text[0]);
    try std.testing.expectEqual(@as(u8, 'o'), initial.cells[0].text[0]);
    const update = try second.render(a, first);
    defer a.free(update);
    first.feed(update);
    try std.testing.expectEqualDeep(second.cells, first.cells);
}

test "UTF-8 split packets wide cells combining marks and rendition" {
    _ = c.setlocale(c.LC_ALL, "C.UTF-8");
    const a = std.testing.allocator;
    var screen = try Screen.init(a, 12, 2);
    defer screen.deinit(a);
    screen.feed("\x1b[38;5;196m\xe7");
    screen.feed("\x95\x8ce\xcc\x81");
    try std.testing.expectEqual(@as(u8, 2), screen.cells[0].width);
    try std.testing.expectEqual(@as(u8, 0), screen.cells[1].width);
    try std.testing.expectEqualStrings("e\xcc\x81", screen.cells[2].text[0..screen.cells[2].len]);
    try std.testing.expectEqual(@as(u32, 197), screen.cells[0].style.fg);
    const frame = try screen.render(a, null);
    defer a.free(frame);
    var copy = try Screen.init(a, 12, 2);
    defer copy.deinit(a);
    copy.feed(frame);
    try std.testing.expectEqualStrings("界", copy.cells[0].text[0..copy.cells[0].len]);
    try std.testing.expectEqual(@as(usize, 3), copy.x);
}
