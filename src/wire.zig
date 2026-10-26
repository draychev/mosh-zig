const std = @import("std");
const c = @import("c.zig").c;
pub const Allocator = std.mem.Allocator;
pub const Bytes = std.ArrayList(u8);
pub const limit = 4 * 1024 * 1024;

pub fn varint(out: *Bytes, a: Allocator, value: u64) !void {
    var n = value;
    while (n >= 128) : (n >>= 7) try out.append(a, @as(u8, @truncate(n)) | 128);
    try out.append(a, @intCast(n));
}
pub fn number(out: *Bytes, a: Allocator, field: u32, value: u64) !void {
    try varint(out, a, @as(u64, field) << 3);
    try varint(out, a, value);
}
pub fn bytes(out: *Bytes, a: Allocator, field: u32, value: []const u8) !void {
    try varint(out, a, (@as(u64, field) << 3) | 2);
    try varint(out, a, value.len);
    try out.appendSlice(a, value);
}
pub const Field = struct { tag: u32, kind: u3, integer: u64 = 0, data: []const u8 = "" };
pub const Reader = struct {
    data: []const u8,
    pos: usize = 0,
    fn integer(self: *Reader) !u64 {
        var value: u64 = 0;
        for (0..10) |i| {
            if (self.pos == self.data.len) return error.TruncatedProtobuf;
            const b = self.data[self.pos];
            self.pos += 1;
            if (i == 9 and b > 1) return error.InvalidProtobuf;
            value |= @as(u64, b & 127) << @as(u6, @intCast(i * 7));
            if (b < 128) return value;
        }
        return error.InvalidProtobuf;
    }
    pub fn next(self: *Reader) !?Field {
        if (self.pos == self.data.len) return null;
        const key = try self.integer();
        if (key >> 3 == 0 or key >> 3 > 0x1fffffff) return error.InvalidProtobuf;
        var f: Field = .{ .tag = @intCast(key >> 3), .kind = @truncate(key) };
        switch (f.kind) {
            0 => f.integer = try self.integer(),
            1, 2, 5 => {
                const len = if (f.kind == 2) try self.integer() else if (f.kind == 1) @as(u64, 8) else 4;
                if (len > self.data.len - self.pos) return error.TruncatedProtobuf;
                f.data = self.data[self.pos..][0..@intCast(len)];
                self.pos += @intCast(len);
            },
            else => return error.InvalidProtobuf,
        }
        return f;
    }
};

pub const Instruction = struct {
    old: u64 = 0,
    new: u64 = 0,
    ack: u64 = 0,
    throwaway: u64 = 0,
    diff: []const u8 = "",
    pub fn decode(data: []const u8) !Instruction {
        var r: Reader = .{ .data = data };
        var result: Instruction = .{};
        var version: u64 = 0;
        while (try r.next()) |f| {
            if (f.tag <= 5 and f.kind != 0) return error.InvalidProtobuf;
            switch (f.tag) {
                1 => version = f.integer,
                2 => result.old = f.integer,
                3 => result.new = f.integer,
                4 => result.ack = f.integer,
                5 => result.throwaway = f.integer,
                6 => {
                    if (f.kind != 2) return error.InvalidProtobuf;
                    result.diff = f.data;
                },
                else => {},
            }
        }
        if (version != 2) return error.ProtocolVersionMismatch;
        return result;
    }
    pub fn encode(self: Instruction, a: Allocator) ![]u8 {
        var out: Bytes = .empty;
        errdefer out.deinit(a);
        try number(&out, a, 1, 2);
        try number(&out, a, 2, self.old);
        try number(&out, a, 3, self.new);
        try number(&out, a, 4, self.ack);
        try number(&out, a, 5, self.throwaway);
        try bytes(&out, a, 6, self.diff);
        var chaff: [16]u8 = undefined;
        std.crypto.random.bytes(&chaff);
        try bytes(&out, a, 7, chaff[0 .. chaff[0] % 16]);
        return out.toOwnedSlice(a);
    }
};

pub fn event(out: *Bytes, a: Allocator, keys: ?[]const u8, width: u16, height: u16) !void {
    var body: Bytes = .empty;
    defer body.deinit(a);
    if (keys) |k| try bytes(&body, a, 4, k) else {
        try number(&body, a, 5, width);
        try number(&body, a, 6, height);
    }
    var ext: Bytes = .empty;
    defer ext.deinit(a);
    try bytes(&ext, a, if (keys != null) 2 else 3, body.items);
    try bytes(out, a, 1, ext.items);
}

pub fn compress(a: Allocator, data: []const u8) ![]u8 {
    var size: c_ulong = c.compressBound(data.len);
    const out = try a.alloc(u8, size);
    defer a.free(out);
    if (c.compress2(out.ptr, &size, data.ptr, data.len, 3) != c.Z_OK) return error.CompressionFailed;
    return a.dupe(u8, out[0..size]);
}
pub fn decompress(a: Allocator, data: []const u8) ![]u8 {
    var capacity: usize = 4096;
    while (capacity <= limit) : (capacity *= 2) {
        const out = try a.alloc(u8, capacity);
        defer a.free(out);
        var size: c_ulong = capacity;
        const rc = c.uncompress(out.ptr, &size, data.ptr, data.len);
        if (rc == c.Z_OK) return a.dupe(u8, out[0..size]);
        if (rc != c.Z_BUF_ERROR) return error.InvalidCompression;
    }
    return error.MessageTooLarge;
}

pub const Cipher = struct {
    key: [16]u8,
    pub fn init(key: []const u8) !Cipher {
        if (key.len != 22) return error.InvalidKey;
        var result: Cipher = undefined;
        try std.base64.standard_no_pad.Decoder.decode(&result.key, key);
        var encoded: [22]u8 = undefined;
        _ = std.base64.standard_no_pad.Encoder.encode(&encoded, &result.key);
        if (!std.mem.eql(u8, &encoded, key)) return error.InvalidKey;
        return result;
    }
    pub fn seal(self: *const Cipher, out: []u8, seq: u64, plain: []const u8) ![]u8 {
        if (out.len < plain.len + 24) return error.MessageTooLarge;
        std.mem.writeInt(u64, out[0..8], seq, .big);
        var nonce: [12]u8 = @splat(0);
        @memcpy(nonce[4..], out[0..8]);
        const ctx = c.EVP_CIPHER_CTX_new() orelse return error.CryptoFailed;
        defer c.EVP_CIPHER_CTX_free(ctx);
        try check(c.EVP_EncryptInit_ex(ctx, c.EVP_aes_128_ocb(), null, null, null));
        try check(c.EVP_CIPHER_CTX_ctrl(ctx, c.EVP_CTRL_AEAD_SET_IVLEN, 12, null));
        try check(c.EVP_EncryptInit_ex(ctx, null, null, &self.key, &nonce));
        var n: c_int = 0;
        try check(c.EVP_EncryptUpdate(ctx, out[8..].ptr, &n, plain.ptr, @intCast(plain.len)));
        var end: c_int = 0;
        try check(c.EVP_EncryptFinal_ex(ctx, out[8 + @as(usize, @intCast(n)) ..].ptr, &end));
        try check(c.EVP_CIPHER_CTX_ctrl(ctx, c.EVP_CTRL_AEAD_GET_TAG, 16, out[8 + plain.len ..].ptr));
        return out[0 .. plain.len + 24];
    }
    pub fn open(self: *const Cipher, out: []u8, packet: []const u8) ![]u8 {
        if (packet.len < 24 or out.len < packet.len - 24) return error.InvalidPacket;
        var nonce: [12]u8 = @splat(0);
        @memcpy(nonce[4..], packet[0..8]);
        const ctx = c.EVP_CIPHER_CTX_new() orelse return error.CryptoFailed;
        defer c.EVP_CIPHER_CTX_free(ctx);
        try check(c.EVP_DecryptInit_ex(ctx, c.EVP_aes_128_ocb(), null, null, null));
        try check(c.EVP_CIPHER_CTX_ctrl(ctx, c.EVP_CTRL_AEAD_SET_IVLEN, 12, null));
        try check(c.EVP_DecryptInit_ex(ctx, null, null, &self.key, &nonce));
        const len = packet.len - 24;
        var n: c_int = 0;
        try check(c.EVP_DecryptUpdate(ctx, out.ptr, &n, packet[8..].ptr, @intCast(len)));
        try check(c.EVP_CIPHER_CTX_ctrl(ctx, c.EVP_CTRL_AEAD_SET_TAG, 16, @constCast(packet[8 + len ..].ptr)));
        var end: c_int = 0;
        if (c.EVP_DecryptFinal_ex(ctx, out[@intCast(n)..].ptr, &end) != 1) return error.AuthenticationFailed;
        return out[0..len];
    }
    fn check(rc: c_int) !void {
        if (rc != 1) return error.CryptoFailed;
    }
};

// Retain several interleaved assemblies; fragments may arrive out of order.
pub const Assembly = struct {
    id: ?u64 = null,
    parts: std.AutoHashMapUnmanaged(u16, []u8) = .empty,
    total: ?u16 = null,
    size: usize = 0,
    pub fn deinit(self: *Assembly, a: Allocator) void {
        var it = self.parts.valueIterator();
        while (it.next()) |part| a.free(part.*);
        self.parts.deinit(a);
        self.* = .{};
    }
    pub fn add(self: *Assembly, a: Allocator, fragment: []const u8) !?[]u8 {
        if (fragment.len < 10) return error.InvalidFragment;
        const id = std.mem.readInt(u64, fragment[0..8], .big);
        if (self.id != null and self.id.? != id) self.deinit(a);
        self.id = id;
        const packed_num = std.mem.readInt(u16, fragment[8..10], .big);
        const num = packed_num & 0x7fff;
        if (num >= 4096) return error.MessageTooLarge;
        if (packed_num & 0x8000 != 0) {
            if (self.total != null and self.total.? != num + 1) return error.InvalidFragment;
            self.total = num + 1;
        }
        if (self.total) |total| {
            if (num >= total) return error.InvalidFragment;
        }
        if (self.parts.get(num)) |old| {
            if (!std.mem.eql(u8, old, fragment[10..])) return error.InvalidFragment;
        } else {
            if (self.size + fragment.len - 10 > limit) return error.MessageTooLarge;
            const copy = try a.dupe(u8, fragment[10..]);
            errdefer a.free(copy);
            try self.parts.put(a, num, copy);
            self.size += copy.len;
        }
        const total = self.total orelse return null;
        if (self.parts.count() != total) return null;
        var joined: Bytes = .empty;
        defer joined.deinit(a);
        for (0..total) |i| try joined.appendSlice(a, self.parts.get(@intCast(i)) orelse return error.InvalidFragment);
        const result = try decompress(a, joined.items);
        self.deinit(a);
        return result;
    }
};

test "protobuf bounds and 64-bit shutdown state" {
    const a = std.testing.allocator;
    const encoded = try (Instruction{ .new = std.math.maxInt(u64), .diff = "hello" }).encode(a);
    defer a.free(encoded);
    const inst = try Instruction.decode(encoded);
    try std.testing.expectEqual(std.math.maxInt(u64), inst.new);
    try std.testing.expectEqualStrings("hello", inst.diff);
    var bad: Reader = .{ .data = "\x0a\xff\xff\xff\xff\xff\xff\xff\xff\xff\x7f" };
    try std.testing.expectError(error.InvalidProtobuf, bad.next());
}
test "OCB authentication rejects altered nonce ciphertext and tag" {
    const cipher = try Cipher.init("AAAAAAAAAAAAAAAAAAAAAA");
    var packet: [128]u8 = undefined;
    var plain: [128]u8 = undefined;
    const encrypted = try cipher.seal(&packet, 42, "Mosh protocol test");
    try std.testing.expectEqualStrings("Mosh protocol test", try cipher.open(&plain, encrypted));
    for ([_]usize{ 0, 9, encrypted.len - 1 }) |i| {
        packet[i] ^= 1;
        try std.testing.expectError(error.AuthenticationFailed, cipher.open(&plain, encrypted));
        packet[i] ^= 1;
    }
}
test "fragment reassembly tolerates duplicates and reordering" {
    const a = std.testing.allocator;
    const compressed = try compress(a, "reordered fragmented message");
    defer a.free(compressed);
    var assembly: Assembly = .{};
    defer assembly.deinit(a);
    var first: [128]u8 = @splat(0);
    var last: [128]u8 = @splat(0);
    std.mem.writeInt(u16, last[8..10], 0x8001, .big);
    @memcpy(first[10..][0..5], compressed[0..5]);
    @memcpy(last[10..][0 .. compressed.len - 5], compressed[5..]);
    try std.testing.expect(try assembly.add(a, last[0 .. compressed.len + 5]) == null);
    try std.testing.expect(try assembly.add(a, last[0 .. compressed.len + 5]) == null);
    const result = (try assembly.add(a, first[0..15])).?;
    defer a.free(result);
    try std.testing.expectEqualStrings("reordered fragmented message", result);
}
