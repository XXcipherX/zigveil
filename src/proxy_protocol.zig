//! The fallback's bounded PROXY v2 preamble; no TLVs or client input parsing.
const std = @import("std");
const Address = std.Io.net.IpAddress;
pub const max_header_bytes = 52;
pub const PrepareResult = union(enum) { ok: u8, err: std.os.linux.E, unsupported };

pub fn encode(out: *[max_header_bytes]u8, source: Address, destination: Address) error{MixedAddressFamilies}!u8 {
    const src = effective(source);
    const dst = effective(destination);
    @memcpy(out[0..12], "\r\n\r\n\x00\r\nQUIT\n");
    out[12] = 0x21; // Version 2, PROXY command, TCP stream.
    if (src == .ip4 and dst == .ip4) {
        out[13] = 0x11;
        std.mem.writeInt(u16, out[14..16], 12, .big);
        @memcpy(out[16..20], &src.ip4.bytes);
        @memcpy(out[20..24], &dst.ip4.bytes);
        std.mem.writeInt(u16, out[24..26], src.ip4.port, .big);
        std.mem.writeInt(u16, out[26..28], dst.ip4.port, .big);
        return 28;
    }
    // A mapped endpoint paired with native IPv6 retains the socket's IPv6 form.
    if (source == .ip6 and destination == .ip6) {
        out[13] = 0x21;
        std.mem.writeInt(u16, out[14..16], 36, .big);
        @memcpy(out[16..32], &source.ip6.bytes);
        @memcpy(out[32..48], &destination.ip6.bytes);
        std.mem.writeInt(u16, out[48..50], source.ip6.port, .big);
        std.mem.writeInt(u16, out[50..52], destination.ip6.port, .big);
        return 52;
    }
    return error.MixedAddressFamilies;
}

fn effective(address: Address) Address {
    return switch (address) {
        .ip4 => address,
        .ip6 => |value| Address.fromIp6(value),
    };
}

test "exact IPv4 and IPv6 signature, command, addresses and network-order ports" {
    var out: [max_header_bytes]u8 = undefined;
    const n4 = try encode(&out, try Address.parseLiteral("192.0.2.9:4660"), try Address.parseLiteral("198.51.100.7:443"));
    try std.testing.expectEqual(@as(u8, 28), n4);
    try std.testing.expectEqualSlices(u8, "\r\n\r\n\x00\r\nQUIT\n\x21\x11\x00\x0c" ++
        "\xc0\x00\x02\x09\xc6\x33\x64\x07\x12\x34\x01\xbb", out[0..n4]);
    const n6 = try encode(&out, try Address.parseLiteral("[2001:db8::9]:4660"), try Address.parseLiteral("[2001:db8::7]:443"));
    try std.testing.expectEqual(@as(u8, 52), n6);
    try std.testing.expectEqualSlices(u8, "\r\n\r\n\x00\r\nQUIT\n\x21\x21\x00\x24" ++
        "\x20\x01\x0d\xb8\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x09" ++
        "\x20\x01\x0d\xb8\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x07\x12\x34\x01\xbb", out[0..n6]);
}

test "mapped endpoints normalize as a pair, native IPv6 retains mapped bytes, mixed families reject" {
    var out: [max_header_bytes]u8 = undefined;
    const mapped = try Address.parseLiteral("[::ffff:192.0.2.9]:4660");
    const native4 = try Address.parseLiteral("198.51.100.7:443");
    const native6 = try Address.parseLiteral("[2001:db8::7]:443");
    const mapped_dst = try Address.parseLiteral("[::ffff:198.51.100.7]:443");
    for ([_]Address{ native4, mapped_dst }) |dst| {
        try std.testing.expectEqual(@as(u8, 28), try encode(&out, mapped, dst));
        try std.testing.expectEqualSlices(u8, &.{ 192, 0, 2, 9, 198, 51, 100, 7, 0x12, 0x34, 0x01, 0xbb }, out[16..28]);
    }
    try std.testing.expectEqual(@as(u8, 52), try encode(&out, mapped, native6));
    try std.testing.expectEqualSlices(u8, &mapped.ip6.bytes, out[16..32]);
    try std.testing.expectEqual(@as(u8, 52), try encode(&out, native6, mapped));
    try std.testing.expectEqualSlices(u8, &mapped.ip6.bytes, out[32..48]);
    try std.testing.expectError(error.MixedAddressFamilies, encode(&out, native4, native6));
    try std.testing.expectError(error.MixedAddressFamilies, encode(&out, native6, native4));
}
