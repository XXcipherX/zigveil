const std = @import("std");

/// Owned, canonical ASCII DNS name. No slices survive staging-buffer release.
pub const Name = struct {
    bytes: [253]u8 = undefined,
    len: u8,

    pub fn parse(input: []const u8) error{InvalidHostname}!Name {
        if (input.len == 0 or input.len > 253) return error.InvalidHostname;
        var result: Name = .{ .len = @intCast(input.len) };
        var label_start: usize = 0;
        for (input, 0..) |byte, index| {
            const c = std.ascii.toLower(byte);
            if (c == '.') {
                if (index == label_start or index - label_start > 63 or input[index - 1] == '-') return error.InvalidHostname;
                label_start = index + 1;
            } else {
                if (!(std.ascii.isAlphanumeric(c) or c == '-') or (index == label_start and c == '-')) return error.InvalidHostname;
            }
            result.bytes[index] = c;
        }
        if (label_start == input.len or input.len - label_start > 63 or input[input.len - 1] == '-') return error.InvalidHostname;
        // RFC 6066 does not permit IP literals as host_name.
        if (std.Io.net.Ip4Address.parse(input, 1)) |_| return error.InvalidHostname else |_| {}
        return result;
    }

    pub fn slice(self: *const Name) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn eql(a: *const Name, b: *const Name) bool {
        return std.mem.eql(u8, a.slice(), b.slice());
    }
};

test "hostname canonicalization and syntax" {
    const name = try Name.parse("Example.COM");
    try std.testing.expectEqualStrings("example.com", name.slice());
    for ([_][]const u8{ "", ".example", "example.", "a..b", "-a.b", "a-.b", "a_b", "127.0.0.1", "a\x00b", "a/b" }) |bad| {
        try std.testing.expectError(error.InvalidHostname, Name.parse(bad));
    }
    const long = [_]u8{'a'} ** 64;
    try std.testing.expectError(error.InvalidHostname, Name.parse(&long));
}
