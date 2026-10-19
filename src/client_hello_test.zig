const std = @import("std");
const parser = @import("client_hello.zig");
const parse = parser.parse;
const max_wire_bytes = parser.max_wire_bytes;

test "complete hello, every TCP prefix, coalesced extra payload" {
    var storage: [1024]u8 = undefined;
    const hello = @import("test_hello.zig").make(&storage, .{ .name = "Example.COM" });
    for (0..hello.len) |n| try std.testing.expect(parse(hello[0..n]) == .need_more);
    const name = parse(hello).ok.?;
    try std.testing.expectEqualStrings("example.com", name.slice());
    @memcpy(storage[hello.len..][0..5], "EXTRA");
    try std.testing.expect(parse(storage[0 .. hello.len + 5]) == .ok);
    try std.testing.expectEqualStrings("EXTRA", storage[hello.len..][0..5]);
}

test "multi-record hello including split handshake header and SNI" {
    var storage: [1024]u8 = undefined;
    const hello = @import("test_hello.zig").make(&storage, .{ .fragment_bytes = 2 });
    for (0..hello.len) |n| try std.testing.expect(parse(hello[0..n]) == .need_more);
    const name = parse(hello).ok.?;
    try std.testing.expectEqualStrings("example.com", name.slice());
}

test "missing SNI and invalid lengths, trailing extensions, duplicate SNI" {
    var storage: [2048]u8 = undefined;
    const missing = @import("test_hello.zig").make(&storage, .{ .name = null });
    try std.testing.expect(parse(missing).ok == null);
    const hello = @import("test_hello.zig").make(&storage, .{});
    storage[3] = 0xff;
    try std.testing.expect(parse(hello) == .invalid);
    _ = @import("test_hello.zig").make(&storage, .{});
    storage[6] = 0xff;
    try std.testing.expect(parse(hello) == .invalid);
    const duplicate = @import("test_hello.zig").make(&storage, .{ .duplicate_sni = true });
    try std.testing.expect(parse(duplicate) == .invalid);
    const trailing = @import("test_hello.zig").make(&storage, .{ .bad_tail = true });
    try std.testing.expect(parse(trailing) == .invalid);
    const invalid_name = @import("test_hello.zig").make(&storage, .{ .name = "a..b" });
    try std.testing.expect(parse(invalid_name) == .invalid);
}

test "maximum wire size, over-limit records, hostile record fragmentation" {
    var storage: [max_wire_bytes + 1]u8 = undefined;
    const hello = @import("test_hello.zig").make(&storage, .{ .handshake_bytes = max_wire_bytes - 20 });
    try std.testing.expectEqual(@as(usize, max_wire_bytes), hello.len);
    try std.testing.expect(parse(hello) == .ok);
    try std.testing.expect(parse(&storage) == .invalid);
    const many = @import("test_hello.zig").make(&storage, .{ .fragment_bytes = 1 });
    try std.testing.expect(parse(many) == .invalid);
    try std.testing.expect(parse(&.{ 22, 3, 1, 0, 0 }) == .invalid);
}
