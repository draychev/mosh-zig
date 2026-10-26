const std = @import("std");
const c = @import("c.zig").c;
const wire = @import("wire.zig");
const Screen = @import("terminal.zig").Screen;
const A = std.mem.Allocator;
pub const shutdown = std.math.maxInt(u64);
pub fn now() u64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(u64, @intCast(ts.tv_sec)) * 1000 + @as(u64, @intCast(ts.tv_nsec)) / 1000000;
}
pub fn write(data: []const u8) !void {
    var pos: usize = 0;
    while (pos < data.len) {
        const n = c.write(1, data[pos..].ptr, data.len - pos);
        if (n < 0) {
            if (std.posix.errno(n) == .INTR) continue;
            return error.TerminalWriteFailed;
        }
        if (n == 0) return error.TerminalWriteFailed;
        pos += @intCast(n);
    }
}
pub const Client = struct {
    a: A,
    fd: c_int,
    cipher: wire.Cipher,
    seq: u64 = 0,
    replay: Replay = .{},
    fragment_id: u64 = 0,
    timestamp: u16 = 65535,
    timestamp_at: u64 = 0,
    base: u64 = 0,
    sent: u64 = 0,
    remote: u64 = 0,
    pending: wire.Bytes = .empty,
    inflight: wire.Bytes = .empty,
    states: std.AutoHashMapUnmanaged(u64, Screen) = .empty,
    displayed: ?Screen = null,
    assemblies: [4]wire.Assembly = @splat(.{}),
    last_sent: u64 = 0,
    last_heard: u64 = 0,
    ack_due: u64 = shutdown,
    closing: bool = false,
    close_at: u64 = 0,
    done: bool = false,
    verbose: bool = false,
    pub fn init(a: A, ip: []const u8, port: u16, key: []const u8, w: u16, h: u16) !Client {
        const address = try std.net.Address.parseIp(ip, port);
        const fd = c.socket(address.any.family, c.SOCK_DGRAM | c.SOCK_CLOEXEC, 0);
        if (fd < 0) return error.SocketFailed;
        errdefer _ = c.close(fd);
        if (c.connect(fd, @ptrCast(&address.any), address.getOsSockLen()) != 0) return error.ConnectFailed;
        var result: Client = .{ .a = a, .fd = fd, .cipher = try wire.Cipher.init(key) };
        errdefer result.states.deinit(a);
        var screen = try Screen.init(a, w, h);
        errdefer screen.deinit(a);
        try result.states.put(a, 0, screen);
        try wire.event(&result.pending, a, null, w, h);
        return result;
    }
    pub fn receive(self: *Client) !void {
        var packet: [65536]u8 = undefined;
        const len = c.recv(self.fd, &packet, packet.len, c.MSG_DONTWAIT);
        if (len <= 0) return;
        if (len < 38 or packet[0] & 0x80 == 0) return;
        var buffer: [65536]u8 = undefined;
        const plain = self.cipher.open(&buffer, packet[0..@intCast(len)]) catch return;
        if (plain.len < 14) return;
        const sequence = std.mem.readInt(u64, packet[0..8], .big) & 0x7fffffffffffffff;
        if (!self.replay.accept(sequence)) return;
        self.timestamp = std.mem.readInt(u16, plain[0..2], .big);
        self.timestamp_at = now();
        const id = std.mem.readInt(u64, plain[4..12], .big);
        const message = self.assemblies[id % self.assemblies.len].add(self.a, plain[4..]) catch return;
        if (message) |data| {
            defer self.a.free(data);
            const inst = try wire.Instruction.decode(data);
            try self.accept(inst);
        }
    }
    fn accept(self: *Client, inst: wire.Instruction) !void {
        self.last_heard = now();
        if (self.verbose) std.debug.print("\r\nrecv {d}->{d} ack={d} diff={d}\r\n", .{ inst.old, inst.new, inst.ack, inst.diff.len });
        if (inst.ack == self.sent) {
            self.base = self.sent;
            self.inflight.clearRetainingCapacity();
            if (self.closing) self.done = true;
        }
        if (self.states.contains(inst.new)) return;
        const old = self.states.get(inst.old) orelse return;
        var next = try old.clone(self.a);
        var owned = true;
        errdefer if (owned) next.deinit(self.a);
        try next.apply(self.a, inst.diff);
        var remove: std.ArrayList(u64) = .empty;
        defer remove.deinit(self.a);
        var it = self.states.keyIterator();
        while (it.next()) |key| if (key.* < inst.throwaway) {
            try remove.append(self.a, key.*);
        };
        for (remove.items) |key| {
            var entry = self.states.fetchRemove(key).?;
            entry.value.deinit(self.a);
        }
        if (self.states.count() >= 256) {
            next.deinit(self.a);
            return;
        }
        var memory = next.cells.len * @sizeOf(@import("terminal.zig").Cell);
        var retained = self.states.valueIterator();
        while (retained.next()) |screen| memory += screen.cells.len * @sizeOf(@import("terminal.zig").Cell);
        if (memory > 128 * 1024 * 1024) {
            next.deinit(self.a);
            return;
        }
        try self.states.put(self.a, inst.new, next);
        owned = false;
        // Ownership has moved into the retained snapshot map.
        if (inst.new > self.remote) {
            self.remote = inst.new;
            const output = try next.render(self.a, self.displayed);
            defer self.a.free(output);
            try write(output);
            if (self.displayed) |*screen| screen.deinit(self.a);
            self.displayed = null;
            self.displayed = try next.clone(self.a);
            if (inst.diff.len > 0 or inst.new == shutdown) self.ack_due = @min(self.ack_due, now() + 20);
            if (inst.new == shutdown) self.close();
        }
    }
    pub fn close(self: *Client) void {
        if (self.closing) return;
        self.closing = true;
        self.close_at = now();
        self.last_sent = 0;
    }
    pub fn tick(self: *Client) !void {
        if (self.done) return;
        const time = now();
        if (self.closing and time - self.close_at > 3000) {
            self.done = true;
            return;
        }
        if (self.base == self.sent and (self.pending.items.len != 0 or time - self.last_sent >= 3000 or self.ack_due <= time)) {
            std.mem.swap(wire.Bytes, &self.inflight, &self.pending);
            self.pending.clearRetainingCapacity();
            self.sent += 1;
            self.last_sent = 0;
        }
        if (self.closing) self.sent = shutdown;
        const retry: u64 = if (self.last_heard > 0 and time - self.last_heard < 5000) 250 else 1000;
        if (time - self.last_sent < retry and time < self.ack_due) return;
        if (self.sent == self.base and !self.closing) return;
        const encoded = try (wire.Instruction{ .old = self.base, .new = self.sent, .ack = self.remote, .throwaway = self.base, .diff = self.inflight.items }).encode(self.a);
        defer self.a.free(encoded);
        const compressed = try wire.compress(self.a, encoded);
        defer self.a.free(compressed);
        self.fragment_id += 1;
        var offset: usize = 0;
        var fragment: u16 = 0;
        while (offset < compressed.len) : (fragment += 1) {
            const len = @min(450, compressed.len - offset);
            var plain: [464]u8 = undefined;
            std.mem.writeInt(u16, plain[0..2], @intCast(time % 65535), .big);
            const reply: u16 = if (self.timestamp != 65535 and time - self.timestamp_at < 1000) self.timestamp +% @as(u16, @intCast(time - self.timestamp_at)) else 65535;
            std.mem.writeInt(u16, plain[2..4], reply, .big);
            self.timestamp = 65535;
            std.mem.writeInt(u64, plain[4..12], self.fragment_id, .big);
            std.mem.writeInt(u16, plain[12..14], fragment | @as(u16, if (offset + len == compressed.len) 0x8000 else 0), .big);
            @memcpy(plain[14..][0..len], compressed[offset..][0..len]);
            var packet: [512]u8 = undefined;
            if (self.seq >= (1 << 63)) return error.NonceExhausted;
            const data = try self.cipher.seal(&packet, self.seq, plain[0 .. len + 14]);
            self.seq += 1;
            _ = c.send(self.fd, data.ptr, data.len, c.MSG_DONTWAIT);
            offset += len;
        }
        self.last_sent = time;
        self.ack_due = shutdown;
    }
    pub fn deinit(self: *Client) void {
        _ = c.close(self.fd);
        self.pending.deinit(self.a);
        self.inflight.deinit(self.a);
        var it = self.states.valueIterator();
        while (it.next()) |screen| screen.deinit(self.a);
        self.states.deinit(self.a);
        if (self.displayed) |*screen| screen.deinit(self.a);
        for (&self.assemblies) |*assembly| assembly.deinit(self.a);
        std.crypto.secureZero(u8, &self.cipher.key);
    }
};

const Replay = struct {
    seen: [1024]u64 = @splat(shutdown),
    highest: u64 = 0,
    fn accept(self: *Replay, seq: u64) bool {
        if (self.highest -| seq >= self.seen.len) return false;
        const slot = seq % self.seen.len;
        if (self.seen[slot] == seq) return false;
        self.seen[slot] = seq;
        self.highest = @max(self.highest, seq);
        return true;
    }
};

test "replay window accepts reorder but rejects duplicate and ancient packets" {
    var replay: Replay = .{};
    try std.testing.expect(replay.accept(1));
    try std.testing.expect(replay.accept(0));
    try std.testing.expect(!replay.accept(1));
    try std.testing.expect(replay.accept(2000));
    try std.testing.expect(!replay.accept(2));
    try std.testing.expect(replay.accept(1999));
}
