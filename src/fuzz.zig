const std = @import("std");
const hello = @import("client_hello.zig");
const fixture = @import("test_hello.zig");

/// A pure entry point for coverage-guided or external fuzz harnesses as well.
pub fn check(bytes: []const u8) !void {
    switch (hello.parse(bytes)) {
        .need_more => try std.testing.expect(bytes.len < hello.max_wire_bytes),
        .invalid => {},
        .ok => |name| if (name) |value| {
            const reparsed = try hello.Name.parse(value.slice());
            try std.testing.expect(value.eql(&reparsed));
        },
    }
}

test "seeded random attacker input and structured mutations" {
    var generator = std.Random.DefaultPrng.init(0x7a69677665696c);
    const random = generator.random();
    var data: [65537]u8 = undefined;
    for (0..4096) |_| {
        const len = random.uintLessThan(usize, 8192);
        random.bytes(data[0..len]);
        try check(data[0..len]);
    }
    for ([_]usize{ 1, 2, 3, 16384 }) |fragment| {
        const valid = fixture.make(&data, .{ .fragment_bytes = fragment });
        for (0..valid.len) |index| {
            const saved = data[index];
            for ([_]u8{ 0, 1, 22, 127, 255 }) |replacement| {
                data[index] = replacement;
                try check(valid);
            }
            data[index] = saved;
            try check(valid[0..index]);
        }
    }
    const maximum = fixture.make(&data, .{ .handshake_bytes = 65516 });
    try check(maximum);
    for (0..1024) |_| {
        const index = random.uintLessThan(usize, maximum.len);
        const saved = data[index];
        data[index] = random.int(u8);
        try check(maximum);
        data[index] = saved;
    }
    try check(&data);
}
