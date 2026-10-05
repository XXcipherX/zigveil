const std = @import("std");
const outcome = @import("io_result.zig");

pub const snapshot_capacity = 4096;

pub const Counters = struct {
    accepted: u64 = 0,
    active: u64 = 0,
    routed: u64 = 0,
    fallback_routed: u64 = 0,
    unknown_sni: u64 = 0,
    missing_sni: u64 = 0,
    invalid_client_hello: u64 = 0,
    connect_failures: u64 = 0,
    bytes_client_to_backend: u64 = 0,
    bytes_backend_to_client: u64 = 0,
    timeouts: u64 = 0,
    io_errors: u64 = 0,
    client_read_errors: u64 = 0,
    client_write_errors: u64 = 0,
    backend_read_errors: u64 = 0,
    backend_write_errors: u64 = 0,
    client_shutdown_errors: u64 = 0,
    backend_shutdown_errors: u64 = 0,
    client_socket_errors: u64 = 0,
    backend_socket_errors: u64 = 0,
    connection_resets: u64 = 0,
    broken_pipes: u64 = 0,
    not_connected: u64 = 0,
    connection_aborts: u64 = 0,
    socket_timeouts: u64 = 0,
    network_errors: u64 = 0,
    other_io_errors: u64 = 0,
    zero_writes: u64 = 0,
    // Gauge, not an event count: exact most recent errno in other_io_errors.
    last_other_io_errno: u64 = 0,
    rejected: u64 = 0,
    accept_errors: u64 = 0,
    closed: u64 = 0,

    /// One fatal event, with two exclusive dimensions. Never count retries here.
    pub fn recordIo(self: *Counters, side: outcome.Side, operation: outcome.Operation, failure: outcome.Failure) void {
        self.io_errors +%= 1;
        const operation_count = switch (side) {
            .client => switch (operation) {
                .read => &self.client_read_errors,
                .write => &self.client_write_errors,
                .shutdown => &self.client_shutdown_errors,
                .socket_error => &self.client_socket_errors,
            },
            .backend => switch (operation) {
                .read => &self.backend_read_errors,
                .write => &self.backend_write_errors,
                .shutdown => &self.backend_shutdown_errors,
                .socket_error => &self.backend_socket_errors,
            },
        };
        operation_count.* +%= 1;
        switch (failure) {
            .zero_write => self.zero_writes +%= 1,
            .errno => |err| switch (err) {
                .CONNRESET => self.connection_resets +%= 1,
                .PIPE => self.broken_pipes +%= 1,
                .NOTCONN => self.not_connected +%= 1,
                .CONNABORTED => self.connection_aborts +%= 1,
                .TIMEDOUT => self.socket_timeouts +%= 1,
                .NETRESET, .NETDOWN, .NETUNREACH, .HOSTDOWN, .HOSTUNREACH, .NONET => self.network_errors +%= 1,
                else => {
                    self.other_io_errors +%= 1;
                    self.last_other_io_errno = @backingInt(err);
                },
            },
        }
    }

    pub fn snapshot(self: *const Counters, bytes: *[snapshot_capacity]u8) []const u8 {
        const prefix = "{\"event\":\"stats\"";
        @memcpy(bytes[0..prefix.len], prefix);
        var length: usize = prefix.len;
        inline for (@typeInfo(Counters).@"struct".field_names) |field_name| {
            // The compile-time bound includes every u64 at its maximum width.
            const part = std.mem.print(bytes[length..], ",\"" ++ field_name ++ "\":{d}", .{@field(self, field_name)}) catch unreachable;
            length += part.len;
        }
        @memcpy(bytes[length..][0..2], "}\n");
        return bytes[0 .. length + 2];
    }
};

pub const max_snapshot_bytes = blk: {
    var length: usize = "{\"event\":\"stats\"".len + 2;
    for (@typeInfo(Counters).@"struct".field_names, @typeInfo(Counters).@"struct".field_types) |field_name, field_type| {
        if (field_type != u64) @compileError("Update the stats width bound for non-u64 fields");
        length += field_name.len + 4 + 20; // comma, quotes, colon, max u64 digits
    }
    break :blk length;
};

comptime {
    if (max_snapshot_bytes > snapshot_capacity) @compileError("Stats exceed the fixed diagnostic buffer");
}

test "maximum-width snapshot is complete valid JSON within the fixed buffer" {
    var counts: Counters = .{};
    inline for (@typeInfo(Counters).@"struct".field_names) |field_name| @field(counts, field_name) = std.math.maxInt(u64);
    var storage: [snapshot_capacity]u8 = undefined;
    const bytes = counts.snapshot(&storage);
    try std.testing.expectEqual(max_snapshot_bytes, bytes.len);
    try std.testing.expect(std.mem.endsWith(u8, bytes, "}\n"));
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{ .parse_numbers = false });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("stats", parsed.value.object.get("event").?.string);
    try std.testing.expectEqual(@typeInfo(Counters).@"struct".field_names.len + 1, parsed.value.object.count());
    inline for (@typeInfo(Counters).@"struct".field_names) |field_name| {
        try std.testing.expectEqualStrings("18446744073709551615", parsed.value.object.get(field_name).?.number_string);
    }
}
