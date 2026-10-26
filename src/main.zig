const std = @import("std");
const c = @import("c.zig").c;
const boot = @import("bootstrap.zig");
const net = @import("transport.zig");
const wire = @import("wire.zig");
var stopped = std.atomic.Value(bool).init(false);
fn signalHandler(_: c_int) callconv(.c) void {
    stopped.store(true, .monotonic);
}
const help =
    \\Usage: mosh [options] [user@]host [-- command [args...]]
    \\Native Zig Mosh client (SSH bootstrap, encrypted UDP session).
    \\
    \\  -p, --port PORT       Remote UDP port or range
    \\  --ssh-port PORT       SSH port
    \\  -i IDENTITY           SSH identity file
    \\  --server PATH         Remote mosh-server executable
    \\  -v, --verbose         Protocol diagnostics
    \\  -h, --help            Show help
    \\  --version             Show version
    \\
    \\Exit: Ctrl-^ then .   Literal Ctrl-^: Ctrl-^ twice.
    \\Example: ./mosh user@server.example
    \\
;
pub fn main() void {
    run() catch |err| {
        std.debug.print("mosh: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}
fn run() !void {
    const a = std.heap.c_allocator;
    const args = try std.process.argsAlloc(a);
    defer std.process.argsFree(a, args);
    var config: boot.Config = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try net.write(help);
            return;
        }
        if (std.mem.eql(u8, arg, "--version")) {
            try net.write("zig-mosh 0.1.0 (Mosh protocol 2)\n");
            return;
        }
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            config.verbose = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            config.command = args[i + 1 ..];
            break;
        }
        if (arg.len > 0 and arg[0] == '-') {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--port")) config.udp_port = args[i] else if (std.mem.eql(u8, arg, "--ssh-port")) config.ssh_port = args[i] else if (std.mem.eql(u8, arg, "-i")) config.identity = args[i] else if (std.mem.eql(u8, arg, "--server")) config.server = args[i] else return error.UnknownOption;
        } else if (config.host.len == 0) config.host = arg else {
            config.command = args[i..];
            break;
        }
    }
    if (config.host.len == 0) {
        try net.write(help);
        return error.MissingHost;
    }
    if (c.isatty(0) == 0 or c.isatty(1) == 0) return error.InteractiveTerminalRequired;
    _ = c.setlocale(c.LC_ALL, "");
    const core: c.struct_rlimit = .{ .rlim_cur = 0, .rlim_max = 0 };
    _ = c.setrlimit(c.RLIMIT_CORE, &core);
    var connection = try boot.start(a, config);
    defer a.free(connection.ip);
    defer std.crypto.secureZero(u8, &connection.key);
    const size = windowSize();
    var client = try net.Client.init(a, connection.ip, connection.port, &connection.key, size.ws_col, size.ws_row);
    defer client.deinit();
    client.verbose = config.verbose;
    std.debug.print("mosh: {s}:{d} (UDP). Exit with Ctrl-^ then .\n", .{ connection.ip, connection.port });
    try interact(&client);
}
fn interact(client: *net.Client) !void {
    var saved: c.struct_termios = undefined;
    if (c.tcgetattr(0, &saved) != 0) return error.TerminalSetupFailed;
    var raw = saved;
    c.cfmakeraw(&raw);
    if (c.tcsetattr(0, c.TCSANOW, &raw) != 0) return error.TerminalSetupFailed;
    defer {
        _ = c.tcsetattr(0, c.TCSANOW, &saved);
    }
    try net.write("\x1b[?1049h\x1b[0m\x1b[H\x1b[2J");
    defer net.write("\x1b[0m\x1b[r\x1b[?25h\x1b[?1l\x1b[?5l\x1b[?1000l\x1b[?1001l\x1b[?1002l\x1b[?1003l\x1b[?1004l\x1b[?1005l\x1b[?1006l\x1b[?1015l\x1b[?2004l\x1b[?1049l\r\n[mosh session closed]\r\n") catch {};
    const old_term = c.signal(c.SIGTERM, signalHandler);
    const old_int = c.signal(c.SIGINT, signalHandler);
    const old_hup = c.signal(c.SIGHUP, signalHandler);
    const old_pipe = c.signal(c.SIGPIPE, c.SIG_IGN);
    defer {
        _ = c.signal(c.SIGTERM, old_term);
        _ = c.signal(c.SIGINT, old_int);
        _ = c.signal(c.SIGHUP, old_hup);
        _ = c.signal(c.SIGPIPE, old_pipe);
    }
    var size = windowSize();
    var escape = false;
    var disconnected = false;
    const started = net.now();
    while (!client.done) {
        if (stopped.load(.monotonic)) client.close();
        const next_size = windowSize();
        if (next_size.ws_col != size.ws_col or next_size.ws_row != size.ws_row) {
            size = next_size;
            try wire.event(&client.pending, client.a, null, size.ws_col, size.ws_row);
            if (client.displayed) |*screen| screen.deinit(client.a);
            client.displayed = null;
        }
        try client.tick();
        var fds = [_]c.struct_pollfd{
            .{ .fd = client.fd, .events = c.POLLIN, .revents = 0 },
            .{ .fd = 0, .events = if (client.closing or client.pending.items.len > 65536) 0 else c.POLLIN, .revents = 0 },
        };
        _ = c.poll(&fds, fds.len, 20);
        if (fds[0].revents & c.POLLIN != 0) try client.receive();
        if (fds[1].revents & (c.POLLHUP | c.POLLERR) != 0) client.close();
        if (fds[1].revents & c.POLLIN != 0) try readInput(client, &escape);
        const silent = net.now() - (if (client.last_heard == 0) started else client.last_heard);
        if (silent > 5000 and !disconnected) {
            std.debug.print("\r\n[mosh: waiting for UDP connection; retrying. Ctrl-^ . exits]\r\n", .{});
            disconnected = true;
        } else if (silent < 5000 and disconnected) {
            disconnected = false;
            if (client.displayed) |*screen| screen.deinit(client.a);
            client.displayed = null;
        }
    }
}
fn readInput(client: *net.Client, escape: *bool) !void {
    var input: [4096]u8 = undefined;
    const n = c.read(0, &input, input.len);
    if (n <= 0) {
        if (n == 0) client.close();
        return;
    }
    var keys: wire.Bytes = .empty;
    defer keys.deinit(client.a);
    for (input[0..@intCast(n)]) |b| {
        if (escape.*) {
            escape.* = false;
            if (b == '.') {
                client.close();
                break;
            }
            try keys.append(client.a, 30);
            if (b == 30) continue;
        } else if (b == 30) {
            escape.* = true;
            continue;
        }
        try keys.append(client.a, b);
    }
    if (keys.items.len > 0) try wire.event(&client.pending, client.a, keys.items, 0, 0);
}
fn windowSize() c.struct_winsize {
    var size: c.struct_winsize = std.mem.zeroes(c.struct_winsize);
    _ = c.ioctl(0, c.TIOCGWINSZ, &size);
    if (size.ws_col == 0) size.ws_col = 80;
    if (size.ws_row == 0) size.ws_row = 24;
    size.ws_col = @min(size.ws_col, 1000);
    size.ws_row = @min(size.ws_row, 500);
    return size;
}
test {
    _ = @import("transport.zig");
    _ = @import("wire.zig");
    _ = @import("terminal.zig");
    _ = @import("bootstrap.zig");
}
