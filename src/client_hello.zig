//! Pure bounded record-hopping parser. The original wire image is never changed.
const std = @import("std");
pub const Name = @import("name.zig").Name;
pub const max_wire_bytes = 64 * 1024;
pub const max_records = 64;
pub const Result = union(enum) { need_more, invalid, ok: ?Name };
const ParseError = error{ NeedMore, Invalid };

/// Partial TCP deliveries and fields split across TLS records use the same cursor.
const Wire = struct {
    bytes: []const u8,
    pos: usize = 0,
    end: usize = 0,
    records: usize = 0,

    fn available(self: *Wire) ParseError!usize {
        if (self.pos == self.end) {
            if (self.records == max_records) return error.Invalid;
            if (self.pos == self.bytes.len) return error.NeedMore;
            if (self.bytes[self.pos] != 22) return error.Invalid;
            if (self.bytes.len - self.pos < 5) return error.NeedMore;
            const n = std.mem.readInt(u16, self.bytes[self.pos + 3 ..][0..2], .big);
            if (n == 0 or n > 16384) return error.Invalid;
            if (self.pos > max_wire_bytes - 5 - @as(usize, n)) return error.Invalid;
            self.pos += 5;
            self.end = self.pos + n;
            self.records += 1;
        }
        if (self.pos == self.bytes.len) return error.NeedMore;
        return @min(self.end, self.bytes.len) - self.pos;
    }

    fn byte(self: *Wire) ParseError!u8 {
        _ = try self.available();
        const value = self.bytes[self.pos];
        self.pos += 1;
        return value;
    }

    fn skip(self: *Wire, count: usize) ParseError!void {
        var remaining = count;
        while (remaining != 0) {
            const n = @min(remaining, try self.available());
            self.pos += n;
            remaining -= n;
        }
    }

    fn copy(self: *Wire, output: []u8) ParseError!void {
        var done: usize = 0;
        while (done != output.len) {
            const n = @min(output.len - done, try self.available());
            @memcpy(output[done..][0..n], self.bytes[self.pos..][0..n]);
            self.pos += n;
            done += n;
        }
    }
};

const Body = struct {
    wire: Wire,
    remaining: usize,

    fn skip(self: *Body, n: usize) ParseError!void {
        if (n > self.remaining) return error.Invalid;
        try self.wire.skip(n);
        self.remaining -= n;
    }

    fn int(self: *Body, comptime T: type) ParseError!T {
        const n = @sizeOf(T);
        if (n > self.remaining) return error.Invalid;
        var value: u32 = 0;
        for (0..n) |_| value = (value << 8) | try self.wire.byte();
        self.remaining -= n;
        return @intCast(value);
    }
};

pub fn parse(bytes: []const u8) Result {
    if (bytes.len > max_wire_bytes) return .invalid;
    return .{ .ok = parseInner(bytes) catch |err| return switch (err) {
        error.NeedMore => if (bytes.len == max_wire_bytes) .invalid else .need_more,
        error.Invalid => .invalid,
    } };
}

fn parseInner(bytes: []const u8) ParseError!?Name {
    var wire: Wire = .{ .bytes = bytes };
    if (try wire.byte() != 1) return error.Invalid;
    const body_len = (@as(usize, try wire.byte()) << 16) |
        (@as(usize, try wire.byte()) << 8) | @as(usize, try wire.byte());
    if (body_len < 41 or body_len > max_wire_bytes - 9) return error.Invalid;
    // First prove the whole declared message is present. Incremental deliveries
    // only walk record boundaries; the structured body is parsed once complete.
    var complete = wire;
    try complete.skip(body_len);
    var body: Body = .{ .wire = wire, .remaining = body_len };
    try body.skip(34); // legacy_version + random; version negotiation is opaque.
    const session_len = try body.int(u8);
    if (session_len > 32) return error.Invalid;
    try body.skip(session_len);
    const cipher_len = try body.int(u16);
    if (cipher_len < 2 or cipher_len % 2 != 0) return error.Invalid;
    try body.skip(cipher_len);
    const compression_len = try body.int(u8);
    if (compression_len == 0) return error.Invalid;
    try body.skip(compression_len);
    if (body.remaining == 0) return null; // TLS 1.2 without extensions.
    const extensions_len = try body.int(u16);
    if (extensions_len != body.remaining) return error.Invalid;
    var seen_sni = false;
    var name: ?Name = null;
    while (body.remaining != 0) {
        const kind = try body.int(u16);
        const len = try body.int(u16);
        if (len > body.remaining) return error.Invalid;
        if (kind != 0) {
            try body.skip(len);
            continue;
        }
        if (seen_sni or len < 5) return error.Invalid;
        seen_sni = true;
        const after = body.remaining - len;
        const list_len = try body.int(u16);
        if (list_len != len - 2 or list_len == 0) return error.Invalid;
        while (body.remaining > after) {
            if (body.remaining - after < 3) return error.Invalid;
            const name_type = try body.int(u8);
            const name_len = try body.int(u16);
            if (name_len == 0 or name_len > body.remaining - after) return error.Invalid;
            if (name_type != 0) {
                try body.skip(name_len);
                continue;
            }
            if (name != null or name_len > 253) return error.Invalid;
            var raw: [253]u8 = undefined;
            try body.wire.copy(raw[0..name_len]);
            body.remaining -= name_len;
            name = Name.parse(raw[0..name_len]) catch return error.Invalid;
        }
    }
    return name;
}
