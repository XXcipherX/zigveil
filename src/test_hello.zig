//! Independent synthetic wire fixtures; used by tests, never by the daemon.
const std = @import("std");
pub const Options = struct {
    name: ?[]const u8 = "example.com",
    fragment_bytes: usize = 16384,
    handshake_bytes: ?usize = null,
    duplicate_sni: bool = false,
    bad_tail: bool = false,
};

pub fn make(out: []u8, options: Options) []u8 {
    var hs: [65536]u8 = @splat(0);
    hs[0] = 1;
    hs[4] = 3;
    hs[5] = 3;
    var p: usize = 38;
    hs[p] = 0;
    p += 1;
    put16(&hs, &p, 2);
    put16(&hs, &p, 0x1301);
    hs[p] = 1;
    hs[p + 1] = 0;
    p += 2;
    const ext_len_at = p;
    p += 2;
    if (options.name) |name| {
        const count: usize = if (options.duplicate_sni) 2 else 1;
        for (0..count) |_| {
            put16(&hs, &p, 0);
            put16(&hs, &p, name.len + 5);
            put16(&hs, &p, name.len + 3);
            hs[p] = 0;
            p += 1;
            put16(&hs, &p, name.len);
            @memcpy(hs[p..][0..name.len], name);
            p += name.len;
        }
    }
    if (options.handshake_bytes) |target| {
        std.debug.assert(target >= p + 4);
        put16(&hs, &p, 21);
        put16(&hs, &p, target - p - 2);
        p = target;
    }
    if (options.bad_tail) {
        hs[p] = 0xff;
        p += 1;
    }
    std.mem.writeInt(u16, hs[ext_len_at..][0..2], @intCast(p - ext_len_at - 2), .big);
    hs[1] = @intCast((p - 4) >> 16);
    hs[2] = @truncate((p - 4) >> 8);
    hs[3] = @truncate(p - 4);
    var read: usize = 0;
    var written: usize = 0;
    while (read < p) {
        const n = @min(p - read, options.fragment_bytes);
        out[written] = 22;
        out[written + 1] = 3;
        out[written + 2] = 1;
        std.mem.writeInt(u16, out[written + 3 ..][0..2], @intCast(n), .big);
        written += 5;
        @memcpy(out[written..][0..n], hs[read..][0..n]);
        written += n;
        read += n;
    }
    return out[0..written];
}

fn put16(out: []u8, p: *usize, value: usize) void {
    std.mem.writeInt(u16, out[p.*..][0..2], @intCast(value), .big);
    p.* += 2;
}
