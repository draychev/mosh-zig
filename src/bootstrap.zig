const std = @import("std");
const A = std.mem.Allocator;
pub const Config = struct {
    host: []const u8 = "",
    server: []const u8 = "mosh-server",
    ssh_port: ?[]const u8 = null,
    udp_port: ?[]const u8 = null,
    identity: ?[]const u8 = null,
    command: []const []const u8 = &.{},
    verbose: bool = false,
};
pub const Connection = struct { ip: []u8, port: u16, key: [22]u8 };
fn quote(out: *std.ArrayList(u8), a: A, value: []const u8) !void {
    try out.append(a, '\'');
    for (value) |b| {
        if (b == '\'') try out.appendSlice(a, "'\\''") else try out.append(a, b);
    }
    try out.append(a, '\'');
}
pub fn start(a: A, config: Config) !Connection {
    var command: std.ArrayList(u8) = .empty;
    defer command.deinit(a);
    // Use the address actually reached by SSH, honoring aliases and ProxyJump.
    try command.appendSlice(a, "printf 'MOSH IP %s\\n' \"$(printf '%s' \"$SSH_CONNECTION\" | cut -d ' ' -f 3)\"; exec ");
    try quote(&command, a, config.server);
    try command.appendSlice(a, " new -s -c 256 -l LANG=C.UTF-8");
    if (config.udp_port) |p| {
        try command.appendSlice(a, " -p ");
        try quote(&command, a, p);
    }
    if (config.command.len > 0) {
        try command.appendSlice(a, " --");
        for (config.command) |arg| {
            try command.append(a, ' ');
            try quote(&command, a, arg);
        }
    }
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(a);
    try args.appendSlice(a, &.{ "ssh", "-T", "-o", "ConnectTimeout=15" });
    if (config.ssh_port) |p| try args.appendSlice(a, &.{ "-p", p });
    if (config.identity) |i| try args.appendSlice(a, &.{ "-i", i });
    try args.appendSlice(a, &.{ "--", config.host, command.items });
    var child = std.process.Child.init(args.items, a);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    errdefer {
        _ = child.kill() catch {};
    }
    const output = try child.stdout.?.readToEndAlloc(a, 1024 * 1024);
    defer a.free(output);
    defer std.crypto.secureZero(u8, output);
    const term = try child.wait();
    if (term != .Exited or term.Exited != 0) return error.SshBootstrapFailed;
    return parse(a, output);
}
pub fn parse(a: A, output: []const u8) !Connection {
    var ip: ?[]const u8 = null;
    var port: ?u16 = null;
    var key: ?[22]u8 = null;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, "\r \t");
        if (std.mem.startsWith(u8, line, "MOSH IP ")) ip = line[8..];
        if (std.mem.startsWith(u8, line, "MOSH CONNECT ")) {
            var fields = std.mem.tokenizeScalar(u8, line[13..], ' ');
            port = try std.fmt.parseInt(u16, fields.next() orelse return error.InvalidHandshake, 10);
            const value = fields.next() orelse return error.InvalidHandshake;
            if (value.len != 22 or port.? == 0) return error.InvalidHandshake;
            key = value[0..22].*;
        }
    }
    if (ip == null or ip.?.len == 0 or port == null or key == null) return error.MissingMoshHandshake;
    return .{ .ip = try a.dupe(u8, ip.?), .port = port.?, .key = key.? };
}

test "SSH banners CRLF and shell argument quoting" {
    const a = std.testing.allocator;
    // Documentation-only IP and synthetic all-zero key, never live credentials.
    const conn = try parse(a, "Welcome\r\nMOSH IP 192.0.2.1\r\nMOSH CONNECT 60001 AAAAAAAAAAAAAAAAAAAAAA\r\n");
    defer a.free(conn.ip);
    try std.testing.expectEqualStrings("192.0.2.1", conn.ip);
    try std.testing.expectEqual(@as(u16, 60001), conn.port);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try quote(&out, a, "a'b;$(x)");
    try std.testing.expectEqualStrings("'a'\\''b;$(x)'", out.items);
    try std.testing.expectError(error.MissingMoshHandshake, parse(a, "no server available"));
}
