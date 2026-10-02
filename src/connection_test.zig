const std = @import("std");
const Config = @import("config.zig").Config;
const Address = @import("config.zig").Address;
const engine = @import("connection.zig");
const Counters = @import("counters.zig").Counters;
const fixture = @import("test_hello.zig");
const outcome = @import("io_result.zig");

const Endpoint = struct {
    input: []const u8 = "",
    offset: usize = 0,
    output: [131072]u8 = undefined,
    length: usize = 0,
    max_read: usize = 65536,
    max_write: usize = 65536,
    eof: bool = false,
    blocked: bool = false,
    read_error: ?outcome.Errno = null,
    write_error: ?outcome.Errno = null,
    shutdown_error: ?outcome.Errno = null,
    socket_error: ?outcome.Errno = null,
    fins: usize = 0,
    error_checks: usize = 0,
};

const Fake = struct {
    client: Endpoint = .{},
    backend: Endpoint = .{},
    connect_failed: bool = false,
    finish_failed: bool = false,
    immediate: bool = true,
    connects: usize = 0,
    completions: usize = 0,

    fn endpoint(self: *Fake, fd: i32) *Endpoint {
        std.debug.assert(fd == 1 or fd == 2);
        return if (fd == 1) &self.client else &self.backend;
    }

    pub fn recv(self: *Fake, fd: i32, bytes: []u8) outcome.Result(usize) {
        const e = self.endpoint(fd);
        if (e.read_error) |err| return .{ .err = err };
        const n = @min(bytes.len, @min(e.max_read, e.input.len - e.offset));
        if (n == 0) return if (e.eof) .{ .ok = 0 } else .{ .err = .AGAIN };
        @memcpy(bytes[0..n], e.input[e.offset..][0..n]);
        e.offset += n;
        return .{ .ok = n };
    }

    pub fn send(self: *Fake, fd: i32, bytes: []const u8) outcome.Result(usize) {
        const e = self.endpoint(fd);
        if (e.write_error) |err| return .{ .err = err };
        if (e.blocked) return .{ .err = .AGAIN };
        const n = @min(bytes.len, @min(e.max_write, e.output.len - e.length));
        @memcpy(e.output[e.length..][0..n], bytes[0..n]);
        e.length += n;
        return .{ .ok = n };
    }

    pub fn shutdown(self: *Fake, fd: i32) outcome.Result(void) {
        const e = self.endpoint(fd);
        e.fins += 1;
        return if (e.shutdown_error) |err| .{ .err = err } else .{ .ok = {} };
    }

    pub fn checkSocketError(self: *Fake, fd: i32) outcome.Result(void) {
        const e = self.endpoint(fd);
        e.error_checks += 1;
        return if (e.socket_error) |err| .{ .err = err } else .{ .ok = {} };
    }

    pub fn startConnect(self: *Fake, _: Address) !engine.Connect {
        self.connects += 1;
        if (self.connect_failed) return error.ConnectFailed;
        return .{ .fd = 2, .complete = self.immediate };
    }

    pub fn finishConnect(self: *Fake, _: i32) !void {
        self.completions += 1;
        if (self.finish_failed) return error.ConnectFailed;
    }
};

const Rig = struct {
    stage: [65536]u8 = undefined,
    input: [65536]u8 = undefined,
    forward: [32]u8 = undefined,
    reverse: [32]u8 = undefined,
    conn: engine.Connection = undefined,
    io: Fake = .{},
    counts: Counters = .{},
    now: u64 = 1,

    fn init(self: *Rig, options: fixture.Options) void {
        const wire = fixture.make(&self.input, options);
        self.conn = engine.Connection.init(1, &self.stage, &self.forward, &self.reverse, 0);
        self.io.client.input = wire;
    }

    fn drive(self: *Rig, config: *const Config, times: usize) void {
        for (0..times) |_| self.conn.drive(&self.io, config, self.now, true, &self.counts);
    }

    fn relay(self: *Rig) void {
        self.init(.{});
        self.conn.state = .relaying;
        self.conn.stage = null;
        self.conn.backend = 2;
        self.io.client.input = "";
    }
};

fn testConfig() !Config {
    return Config.parse(std.testing.allocator,
        \\{"listen":"127.0.0.1:8443","routes":[{"sni":"example.com","backend":"127.0.0.1:9443"}]}
    );
}

const operation_fields = [_][]const u8{ "client_read_errors", "client_write_errors", "backend_read_errors", "backend_write_errors", "client_shutdown_errors", "backend_shutdown_errors", "client_socket_errors", "backend_socket_errors" };
const cause_fields = [_][]const u8{ "connection_resets", "broken_pipes", "not_connected", "connection_aborts", "socket_timeouts", "network_errors", "other_io_errors", "zero_writes" };

fn expectIoConsistent(counts: Counters) !void {
    var operations: u64 = 0;
    inline for (operation_fields) |field| operations +%= @field(counts, field);
    var causes: u64 = 0;
    inline for (cause_fields) |field| causes +%= @field(counts, field);
    try std.testing.expectEqual(counts.io_errors, operations);
    try std.testing.expectEqual(counts.io_errors, causes);
}

fn expectIoEvent(counts: Counters, operation: []const u8, cause: []const u8) !void {
    try std.testing.expectEqual(@as(u64, 1), counts.io_errors);
    inline for (operation_fields) |field| try std.testing.expectEqual(@as(u64, if (std.mem.eql(u8, field, operation)) 1 else 0), @field(counts, field));
    inline for (cause_fields) |field| try std.testing.expectEqual(@as(u64, if (std.mem.eql(u8, field, cause)) 1 else 0), @field(counts, field));
    try expectIoConsistent(counts);
}

test "coalesced prefix survives blocked and partial writes; both FINs follow all bytes" {
    var config = try testConfig();
    defer config.deinit(std.testing.allocator);
    var rig: Rig = .{};
    rig.init(.{ .name = "ExAmPle.com" });
    const hello_len = rig.io.client.input.len;
    @memcpy(rig.input[hello_len..][0..5], "EXTRA");
    rig.io.client.input = rig.input[0 .. hello_len + 5];
    rig.io.client.eof = true;
    rig.io.backend.input = "response-after-client-fin";
    rig.io.backend.eof = true;
    rig.io.backend.blocked = true;
    rig.drive(&config, 1);
    try std.testing.expectEqual(hello_len + 5, rig.conn.stage_len);
    try std.testing.expectEqual(@as(usize, 0), rig.io.backend.length);
    try std.testing.expect(!rig.conn.interest(false).read);
    try std.testing.expect(rig.conn.interest(true).write);
    rig.io.backend.blocked = false;
    rig.io.backend.max_write = 3;
    rig.io.client.max_write = 2;
    rig.drive(&config, 50);
    try std.testing.expectEqualSlices(u8, rig.io.client.input, rig.io.backend.output[0..rig.io.backend.length]);
    try std.testing.expectEqualStrings(rig.io.backend.input, rig.io.client.output[0..rig.io.client.length]);
    try std.testing.expectEqual(@as(usize, 1), rig.io.client.fins);
    try std.testing.expectEqual(@as(usize, 1), rig.io.backend.fins);
    try std.testing.expectEqual(engine.State.closed, rig.conn.state);
    try std.testing.expectEqual(engine.CloseReason.complete, rig.conn.reason);
    try std.testing.expectEqual(@as(u64, hello_len + 5), rig.counts.bytes_client_to_backend);
    try std.testing.expectEqual(@as(u64, 0), rig.counts.io_errors);
    try expectIoConsistent(rig.counts);
}

test "one byte TCP deliveries and multi-record parsing route exactly once" {
    var config = try testConfig();
    defer config.deinit(std.testing.allocator);
    var rig: Rig = .{};
    rig.init(.{ .fragment_bytes = 3 });
    rig.io.client.max_read = 1;
    rig.drive(&config, 100);
    try std.testing.expectEqual(@as(usize, 1), rig.io.connects);
    try std.testing.expectEqual(@as(u64, 1), rig.counts.routed);
    try std.testing.expectEqualSlices(u8, rig.io.client.input, rig.io.backend.output[0..rig.io.backend.length]);
}

test "backpressure bounds read-ahead, and client half-close permits a later reply" {
    var config = try testConfig();
    defer config.deinit(std.testing.allocator);
    var rig: Rig = .{};
    rig.relay();
    rig.io.client.input = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    rig.io.client.eof = true;
    rig.io.backend.blocked = true;
    rig.drive(&config, 10);
    try std.testing.expectEqual(@as(usize, 32), rig.io.client.offset);
    try std.testing.expectEqual(@as(usize, 32), rig.conn.to_backend.buffer.len);
    try std.testing.expect(!rig.conn.interest(false).read);
    try std.testing.expect(rig.conn.interest(true).write);
    rig.io.backend.blocked = false;
    rig.io.backend.max_write = 1;
    rig.drive(&config, 10);
    try std.testing.expectEqual(@as(usize, 1), rig.io.backend.fins);
    try std.testing.expectEqual(engine.State.relaying, rig.conn.state);
    rig.io.backend.input = "reply";
    rig.io.backend.eof = true;
    rig.drive(&config, 10);
    try std.testing.expectEqual(engine.State.closed, rig.conn.state);
    try std.testing.expectEqualStrings("reply", rig.io.client.output[0..rig.io.client.length]);
    try std.testing.expectEqualSlices(u8, rig.io.client.input, rig.io.backend.output[0..rig.io.backend.length]);
}

test "reverse backpressure and backend half-close preserve the client sending half" {
    var config = try testConfig();
    defer config.deinit(std.testing.allocator);
    var rig: Rig = .{};
    rig.relay();
    rig.io.backend.input = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    rig.io.backend.eof = true;
    rig.io.client.blocked = true;
    rig.drive(&config, 10);
    try std.testing.expectEqual(@as(usize, 32), rig.io.backend.offset);
    try std.testing.expect(!rig.conn.interest(true).read);
    rig.io.client.blocked = false;
    rig.io.client.max_write = 2;
    rig.drive(&config, 10);
    try std.testing.expectEqual(@as(usize, 1), rig.io.client.fins);
    try std.testing.expectEqual(engine.State.relaying, rig.conn.state);
    rig.io.client.input = "last-client-payload";
    rig.io.client.eof = true;
    rig.drive(&config, 10);
    try std.testing.expectEqual(engine.State.closed, rig.conn.state);
    try std.testing.expectEqualSlices(u8, rig.io.backend.input, rig.io.client.output[0..rig.io.client.length]);
    try std.testing.expectEqualStrings(rig.io.client.input, rig.io.backend.output[0..rig.io.backend.length]);
}

test "connect readiness, immediate failure and asynchronous SO_ERROR failure" {
    var config = try testConfig();
    defer config.deinit(std.testing.allocator);
    var pending: Rig = .{};
    pending.init(.{});
    pending.io.immediate = false;
    pending.conn.drive(&pending.io, &config, 1, false, &pending.counts);
    try std.testing.expectEqual(engine.State.connecting, pending.conn.state);
    try std.testing.expectEqual(@as(usize, 0), pending.io.completions);
    pending.io.finish_failed = true;
    pending.drive(&config, 1);
    try std.testing.expectEqual(engine.CloseReason.connect_failed, pending.conn.reason);
    try std.testing.expectEqual(@as(u64, 1), pending.counts.connect_failures);
    try std.testing.expectEqual(@as(u64, 0), pending.counts.io_errors);
    try expectIoConsistent(pending.counts);
    var failed: Rig = .{};
    failed.init(.{});
    failed.io.connect_failed = true;
    failed.drive(&config, 1);
    try std.testing.expectEqual(engine.CloseReason.connect_failed, failed.conn.reason);
    try std.testing.expectEqual(@as(u64, 0), failed.counts.io_errors);
    try expectIoConsistent(failed.counts);
}

test "client and backend resets in either relay operation close the connection" {
    var config = try testConfig();
    defer config.deinit(std.testing.allocator);
    for (0..4) |fault| {
        var rig: Rig = .{};
        rig.relay();
        rig.io.client.input = "forward";
        rig.io.backend.input = "reverse";
        switch (fault) {
            0 => rig.io.client.read_error = .CONNRESET,
            1 => rig.io.backend.read_error = .CONNRESET,
            2 => rig.io.client.write_error = .CONNRESET,
            3 => rig.io.backend.write_error = .CONNRESET,
            else => unreachable,
        }
        rig.drive(&config, 4);
        try std.testing.expectEqual(engine.CloseReason.io_error, rig.conn.reason);
        try expectIoEvent(rig.counts, ([_][]const u8{ "client_read_errors", "backend_read_errors", "client_write_errors", "backend_write_errors" })[fault], "connection_resets");
    }
}

test "absolute hello, connect, prefix and idle deadlines; idle can be disabled" {
    var config = try testConfig();
    defer config.deinit(std.testing.allocator);
    for ([_]engine.State{ .hello, .connecting, .relaying }) |state| {
        var rig: Rig = .{};
        rig.init(.{});
        rig.conn.state = state;
        rig.conn.expire(config.raw.value, 4999, &rig.counts);
        try std.testing.expect(rig.conn.state != .closed);
        rig.conn.expire(config.raw.value, 5000, &rig.counts);
        try std.testing.expectEqual(engine.CloseReason.timeout, rig.conn.reason);
        rig.conn.expire(config.raw.value, 6000, &rig.counts);
        try std.testing.expectEqual(@as(u64, 1), rig.counts.timeouts);
    }
    var idle: Rig = .{};
    idle.relay();
    idle.conn.expire(config.raw.value, 300000, &idle.counts);
    try std.testing.expectEqual(engine.CloseReason.timeout, idle.conn.reason);
    idle.relay();
    config.raw.value.idle_timeout_ms = 0;
    idle.conn.expire(config.raw.value, 9_000_000, &idle.counts);
    try std.testing.expectEqual(engine.State.relaying, idle.conn.state);
}

test "unknown and missing SNI reject, malformed input never takes fallback" {
    var config = try testConfig();
    defer config.deinit(std.testing.allocator);
    for ([_]?[]const u8{ "example.org", null }) |name| {
        var rig: Rig = .{};
        rig.init(.{ .name = name });
        rig.drive(&config, 1);
        try std.testing.expectEqual(engine.CloseReason.no_route, rig.conn.reason);
        try std.testing.expectEqual(@as(usize, 0), rig.io.connects);
    }
    config.fallback = try Address.parseLiteral("127.0.0.1:9444");
    var fallback: Rig = .{};
    fallback.init(.{ .name = "example.org" });
    fallback.drive(&config, 1);
    try std.testing.expectEqual(@as(usize, 1), fallback.io.connects);
    var invalid: Rig = .{};
    invalid.init(.{});
    invalid.input[0] = 23;
    invalid.drive(&config, 1);
    try std.testing.expectEqual(engine.CloseReason.invalid_hello, invalid.conn.reason);
    try std.testing.expectEqual(@as(usize, 0), invalid.io.connects);
    var truncated: Rig = .{};
    truncated.init(.{});
    truncated.io.client.input = truncated.input[0..15];
    truncated.io.client.eof = true;
    truncated.drive(&config, 1);
    try std.testing.expectEqual(engine.CloseReason.invalid_hello, truncated.conn.reason);
}

test "maximum staged prefix is sent without copying into small relay buffers" {
    var config = try testConfig();
    defer config.deinit(std.testing.allocator);
    var rig: Rig = .{};
    rig.init(.{ .handshake_bytes = 65516 });
    rig.io.backend.max_write = 701;
    rig.drive(&config, 100);
    try std.testing.expect(rig.conn.stage == null);
    try std.testing.expectEqualSlices(u8, rig.io.client.input, rig.io.backend.output[0..rig.io.backend.length]);
}

test "ENOTCONN finishes only a drained half and preserves reverse buffered data" {
    var config = try testConfig();
    defer config.deinit(std.testing.allocator);
    for ([_]bool{ false, true }) |reverse| {
        var rig: Rig = .{};
        rig.relay();
        const source = if (reverse) &rig.io.backend else &rig.io.client;
        const target = if (reverse) &rig.io.client else &rig.io.backend;
        const direction = if (reverse) &rig.conn.to_client else &rig.conn.to_backend;
        source.input = "payload-before-half-close";
        source.eof = true;
        target.blocked = true;
        target.shutdown_error = .NOTCONN;
        rig.drive(&config, 1);
        try std.testing.expect(direction.eof);
        try std.testing.expectEqual(source.input.len, direction.buffer.len);
        try std.testing.expectEqual(@as(usize, 0), target.fins);
        target.blocked = false;
        target.max_write = 2;
        rig.drive(&config, 4);
        try std.testing.expectEqualSlices(u8, source.input, target.output[0..target.length]);
        try std.testing.expectEqual(@as(usize, 0), direction.buffer.len);
        try std.testing.expect(direction.fin);
        try std.testing.expectEqual(@as(usize, 1), target.fins);
        try std.testing.expectEqual(@as(usize, 1), target.error_checks);
        try std.testing.expectEqual(@as(u64, 0), rig.counts.io_errors);
        try expectIoConsistent(rig.counts);
        try std.testing.expectEqual(engine.State.relaying, rig.conn.state);
        target.input = "opposite-buffered-data";
        target.eof = true;
        rig.drive(&config, 4);
        try std.testing.expectEqualStrings(target.input, source.output[0..source.length]);
        try std.testing.expectEqual(@as(usize, 1), target.fins);
        try std.testing.expectEqual(@as(usize, 1), source.fins);
        try std.testing.expectEqual(engine.CloseReason.complete, rig.conn.reason);
        try std.testing.expectEqual(engine.State.closed, rig.conn.state);
        try std.testing.expectEqual(@as(u64, 0), rig.counts.io_errors);
    }
}

test "shutdown failures and ENOTCONN with pending reset remain I/O errors" {
    var config = try testConfig();
    defer config.deinit(std.testing.allocator);
    for ([_]bool{ false, true }) |reverse| for ([_]outcome.Errno{ .PIPE, .CONNRESET, .BADF, .NOTCONN }) |failure| {
        var rig: Rig = .{};
        rig.relay();
        const source = if (reverse) &rig.io.backend else &rig.io.client;
        const target = if (reverse) &rig.io.client else &rig.io.backend;
        const direction = if (reverse) &rig.conn.to_client else &rig.conn.to_backend;
        source.input = "all-bytes-before-shutdown";
        source.eof = true;
        target.max_write = 3;
        target.shutdown_error = failure;
        if (failure == .NOTCONN) target.socket_error = .CONNRESET;
        rig.drive(&config, 4);
        try std.testing.expectEqualSlices(u8, source.input, target.output[0..target.length]);
        try std.testing.expectEqual(@as(usize, 0), direction.buffer.len);
        try std.testing.expect(!direction.fin);
        try std.testing.expectEqual(@as(usize, 1), target.fins);
        try std.testing.expectEqual(engine.State.closed, rig.conn.state);
        try std.testing.expectEqual(engine.CloseReason.io_error, rig.conn.reason);
        const operation = if (failure == .NOTCONN)
            (if (reverse) "client_socket_errors" else "backend_socket_errors")
        else
            (if (reverse) "client_shutdown_errors" else "backend_shutdown_errors");
        const cause = switch (failure) {
            .PIPE => "broken_pipes",
            .CONNRESET, .NOTCONN => "connection_resets",
            else => "other_io_errors",
        };
        try expectIoEvent(rig.counts, operation, cause);
    };
}

test "ENOTCONN cannot finish a half while the original prefix is blocked" {
    var config = try testConfig();
    defer config.deinit(std.testing.allocator);
    var rig: Rig = .{};
    rig.init(.{});
    rig.io.client.eof = true;
    rig.io.backend.blocked = true;
    rig.io.backend.shutdown_error = .NOTCONN;
    rig.drive(&config, 4);
    try std.testing.expect(rig.conn.stage != null);
    try std.testing.expectEqual(@as(usize, 0), rig.io.backend.fins);
    rig.io.backend.blocked = false;
    rig.io.backend.max_write = 3;
    rig.drive(&config, 8);
    try std.testing.expect(rig.conn.stage == null);
    try std.testing.expectEqualSlices(u8, rig.io.client.input, rig.io.backend.output[0..rig.io.backend.length]);
    try std.testing.expect(rig.conn.to_backend.fin);
    try std.testing.expectEqual(@as(usize, 1), rig.io.backend.fins);
    try std.testing.expectEqual(@as(u64, 0), rig.counts.io_errors);
    try std.testing.expectEqual(engine.State.relaying, rig.conn.state);
}

test "read errno classes and exact unknown errno traverse the production engine" {
    var config = try testConfig();
    defer config.deinit(std.testing.allocator);
    const cases = [_]struct { err: outcome.Errno, cause: []const u8 }{
        .{ .err = .CONNRESET, .cause = "connection_resets" },
        .{ .err = .NOTCONN, .cause = "not_connected" },
        .{ .err = .CONNABORTED, .cause = "connection_aborts" },
        .{ .err = .TIMEDOUT, .cause = "socket_timeouts" },
        .{ .err = .NETRESET, .cause = "network_errors" },
        .{ .err = .NETDOWN, .cause = "network_errors" },
        .{ .err = .NETUNREACH, .cause = "network_errors" },
        .{ .err = .HOSTDOWN, .cause = "network_errors" },
        .{ .err = .HOSTUNREACH, .cause = "network_errors" },
        .{ .err = .NONET, .cause = "network_errors" },
        .{ .err = .BADF, .cause = "other_io_errors" },
        .{ .err = @enumFromInt(4090), .cause = "other_io_errors" },
    };
    for ([_]bool{ false, true }) |backend| for (cases) |case| {
        var rig: Rig = .{};
        rig.relay();
        (if (backend) &rig.io.backend else &rig.io.client).read_error = case.err;
        rig.drive(&config, 5);
        try std.testing.expectEqual(engine.CloseReason.io_error, rig.conn.reason);
        try expectIoEvent(rig.counts, if (backend) "backend_read_errors" else "client_read_errors", case.cause);
        try std.testing.expectEqual(@as(u64, if (std.mem.eql(u8, case.cause, "other_io_errors")) @intFromEnum(case.err) else 0), rig.counts.last_other_io_errno);
    };
}

test "EPIPE and zero writes identify the destination socket without double counting" {
    var config = try testConfig();
    defer config.deinit(std.testing.allocator);
    for ([_]bool{ false, true }) |backend| for ([_]bool{ false, true }) |zero_write| {
        var rig: Rig = .{};
        rig.relay();
        rig.io.client.input = "forward";
        rig.io.backend.input = "reverse";
        const target = if (backend) &rig.io.backend else &rig.io.client;
        if (zero_write) target.max_write = 0 else target.write_error = .PIPE;
        rig.drive(&config, 5);
        try std.testing.expectEqual(engine.CloseReason.io_error, rig.conn.reason);
        try expectIoEvent(rig.counts, if (backend) "backend_write_errors" else "client_write_errors", if (zero_write) "zero_writes" else "broken_pipes");
        try std.testing.expectEqual(@as(u64, 0), rig.counts.last_other_io_errno);
    };
}

test "hello reads and original prefix writes retain their actual socket operation" {
    var config = try testConfig();
    defer config.deinit(std.testing.allocator);
    for ([_]bool{ false, true }) |prefix| {
        var rig: Rig = .{};
        rig.init(.{});
        if (prefix) rig.io.backend.write_error = .PIPE else rig.io.client.read_error = .CONNRESET;
        rig.drive(&config, 5);
        try expectIoEvent(rig.counts, if (prefix) "backend_write_errors" else "client_read_errors", if (prefix) "broken_pipes" else "connection_resets");
        try std.testing.expectEqual(@as(u64, if (prefix) 1 else 0), rig.counts.routed);
    }
}

test "socket error probes count once and do not invent a read or write failure" {
    var config = try testConfig();
    defer config.deinit(std.testing.allocator);
    for ([_]bool{ false, true }) |backend| {
        var rig: Rig = .{};
        rig.relay();
        const target = if (backend) &rig.io.backend else &rig.io.client;
        rig.conn.checkSocketError(&rig.io, backend, &rig.counts);
        try std.testing.expectEqual(@as(u64, 0), rig.counts.io_errors);
        target.socket_error = .CONNRESET;
        rig.conn.checkSocketError(&rig.io, backend, &rig.counts);
        rig.conn.checkSocketError(&rig.io, backend, &rig.counts);
        rig.drive(&config, 5);
        try std.testing.expectEqual(@as(usize, 2), target.error_checks);
        try expectIoEvent(rig.counts, if (backend) "backend_socket_errors" else "client_socket_errors", "connection_resets");
    }
}

test "would-block and clean FIN keep every I/O error dimension zero" {
    var config = try testConfig();
    defer config.deinit(std.testing.allocator);
    var rig: Rig = .{};
    rig.relay();
    rig.io.client.input = "forward";
    rig.io.backend.input = "reverse";
    rig.io.client.blocked = true;
    rig.io.backend.blocked = true;
    rig.drive(&config, 10);
    try std.testing.expectEqual(@as(u64, 0), rig.counts.io_errors);
    try expectIoConsistent(rig.counts);
    rig.io.client.blocked = false;
    rig.io.backend.blocked = false;
    rig.io.client.eof = true;
    rig.io.backend.eof = true;
    rig.drive(&config, 10);
    try std.testing.expectEqual(engine.CloseReason.complete, rig.conn.reason);
    try std.testing.expectEqualStrings("forward", rig.io.backend.output[0..rig.io.backend.length]);
    try std.testing.expectEqualStrings("reverse", rig.io.client.output[0..rig.io.client.length]);
    try std.testing.expectEqual(@as(u64, 0), rig.counts.io_errors);
    try expectIoConsistent(rig.counts);
}

test "mixed connection failures keep aggregate and both dimensions consistent" {
    var config = try testConfig();
    defer config.deinit(std.testing.allocator);
    var counts: Counters = .{};
    for ([_]outcome.Errno{ .CONNRESET, .PIPE, .NOTCONN, .CONNABORTED, .TIMEDOUT, .NETUNREACH, .BADF, @enumFromInt(4090) }, 0..) |err, index| {
        var rig: Rig = .{};
        rig.relay();
        const backend = index % 2 != 0;
        (if (backend) &rig.io.backend else &rig.io.client).read_error = err;
        rig.conn.drive(&rig.io, &config, rig.now, true, &counts);
        rig.conn.drive(&rig.io, &config, rig.now, true, &counts);
        try expectIoConsistent(counts);
        try std.testing.expectEqual(@as(u64, index + 1), counts.io_errors);
    }
    try std.testing.expectEqual(@as(u64, 4), counts.client_read_errors);
    try std.testing.expectEqual(@as(u64, 4), counts.backend_read_errors);
    try std.testing.expectEqual(@as(u64, 2), counts.other_io_errors);
    try std.testing.expectEqual(@as(u64, 4090), counts.last_other_io_errno);
}
