const std = @import("std");
const Config = @import("config.zig").Config;
const Address = @import("config.zig").Address;
const engine = @import("connection.zig");
const Counters = @import("counters.zig").Counters;
const fixture = @import("test_hello.zig");
const outcome = @import("io_result.zig");
const relay_pipe = @import("relay_pipe.zig");
const proxy_protocol = @import("proxy_protocol.zig");

const FakePipe = struct { data: [65536]u8 = undefined, len: usize = 0 };

const Endpoint = struct {
    input: []const u8 = "",
    offset: usize = 0,
    output: [327680]u8 = undefined,
    length: usize = 0,
    max_read: usize = 65536,
    max_write: usize = 65536,
    writes_left: ?usize = null,
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
    metrics: @import("metrics.zig").Metrics = .{},
    client: Endpoint = .{},
    backend: Endpoint = .{},
    connect_failed: bool = false,
    finish_failed: bool = false,
    immediate: bool = true,
    connects: usize = 0,
    completions: usize = 0,
    destination: ?Address = null,
    proxy_queries: usize = 0,
    proxy_error: ?outcome.Errno = null,
    proxy_unsupported: bool = false,
    peer: Address = .{ .ip4 = .{ .bytes = .{ 192, 0, 2, 9 }, .port = 4660 } },
    local: Address = .{ .ip4 = .{ .bytes = .{ 198, 51, 100, 7 }, .port = 443 } },
    use_pipes: bool = false,
    pipes: [2]FakePipe = .{ .{}, .{} },
    open_attempts: usize = 0,
    pipe_fds_closed: usize = 0,
    pipe_read_blocked: bool = false,
    pipe_page_full: bool = false,
    max_splice_read: usize = 32,
    pipe_capacity: usize = 32,
    splice_reads: usize = 0,
    shared_open: bool = false,
    pipe_attempted: bool = false,
    reclaim_error: ?outcome.Errno = null,

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
        if (e.blocked or e.writes_left == 0) return .{ .err = .AGAIN };
        const n = @min(bytes.len, @min(e.max_write, e.output.len - e.length));
        @memcpy(e.output[e.length..][0..n], bytes[0..n]);
        e.length += n;
        if (e.writes_left) |*left| left.* -= 1;
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

    pub fn prepareProxyHeader(self: *Fake, fd: i32, header: *[proxy_protocol.max_header_bytes]u8) proxy_protocol.PrepareResult {
        std.debug.assert(fd == 1);
        self.proxy_queries += 1;
        if (self.proxy_error) |err| return .{ .err = err };
        if (self.proxy_unsupported) return .unsupported;
        return .{ .ok = proxy_protocol.encode(header, self.peer, self.local) catch return .unsupported };
    }

    pub fn startConnect(self: *Fake, destination: Address) !engine.Connect {
        self.connects += 1;
        self.destination = destination;
        if (self.connect_failed) return error.ConnectFailed;
        return .{ .fd = 2, .complete = self.immediate };
    }

    pub fn finishConnect(self: *Fake, _: i32) !void {
        self.completions += 1;
        if (self.finish_failed) return error.ConnectFailed;
    }

    pub fn openRelayPipes(self: *Fake, _: usize) ?relay_pipe.Pair {
        if (!self.pipe_attempted) self.open_attempts += 1;
        if (self.pipe_attempted and !self.shared_open) return null;
        self.pipe_attempted = true;
        if (!self.use_pipes) return null;
        if (!self.shared_open) self.pipes = .{ .{}, .{} };
        self.shared_open = true;
        return .{ .{ .fds = .{ 10, 11 }, .capacity = self.pipe_capacity }, .{ .fds = .{ 12, 13 }, .capacity = self.pipe_capacity } };
    }

    pub fn readRelayPipe(self: *Fake, fd: i32, bytes: []u8) outcome.Result(usize) {
        if (self.reclaim_error) |err| return .{ .err = err };
        const pipe = &self.pipes[if (fd == 10) @as(usize, 0) else 1];
        const n = @min(bytes.len, pipe.len);
        @memcpy(bytes[0..n], pipe.data[0..n]);
        @memmove(pipe.data[0 .. pipe.len - n], pipe.data[n..pipe.len]);
        pipe.len -= n;
        return .{ .ok = n };
    }

    pub fn disableSharedPipes(self: *Fake) void {
        if (self.shared_open) self.pipe_fds_closed += 4;
        self.shared_open = false;
        self.use_pipes = false;
        self.pipes = .{ .{}, .{} };
    }

    pub fn spliceRead(self: *Fake, source: i32, fd: i32, bytes: usize) outcome.Result(usize) {
        self.splice_reads += 1;
        std.debug.assert(fd == 11 or fd == 13);
        const pipe = &self.pipes[if (fd == 11) @as(usize, 0) else 1];
        if (self.pipe_read_blocked or (self.pipe_page_full and pipe.len != 0)) return .{ .err = .AGAIN };
        const result = self.recv(source, pipe.data[pipe.len..][0..@min(bytes, @min(self.max_splice_read, pipe.data.len - pipe.len))]);
        switch (result) {
            .ok => |n| pipe.len += n,
            .err => {},
        }
        return result;
    }

    pub fn spliceWrite(self: *Fake, fd: i32, target: i32, bytes: usize) outcome.Result(usize) {
        std.debug.assert(fd == 10 or fd == 12);
        const pipe = &self.pipes[if (fd == 10) @as(usize, 0) else 1];
        const result = self.send(target, pipe.data[0..@min(pipe.len, bytes)]);
        switch (result) {
            .ok => |n| {
                @memmove(pipe.data[0 .. pipe.len - n], pipe.data[n..pipe.len]);
                pipe.len -= n;
            },
            .err => {},
        }
        return result;
    }
};

const Rig = struct {
    stage: [65536 + proxy_protocol.max_header_bytes]u8 = undefined,
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
        for (0..times) |_| {
            self.conn.drive(&self.io, config, self.now, true, &self.counts);
        }
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

test "byte fairness yields before another read and lets the opposite FIN progress" {
    var config = try testConfig();
    defer config.deinit(std.testing.allocator);
    var rig: Rig = .{};
    rig.relay();
    var payload: [engine.relay_byte_budget + 23]u8 = undefined;
    for (&payload, 0..) |*byte, i| byte.* = @truncate(i);
    var forward: [65536]u8 = undefined;
    rig.conn.to_backend.buffer = .{ .data = &forward };
    rig.io.client.input = &payload;
    rig.io.client.eof = true;
    rig.io.backend.input = "reply";
    rig.io.backend.eof = true;
    rig.drive(&config, 1);
    try std.testing.expectEqual(@as(usize, engine.relay_byte_budget), rig.io.client.offset);
    try std.testing.expectEqual(@as(usize, 0), rig.conn.to_backend.buffer.len);
    try std.testing.expect(rig.conn.interest(false).read);
    try std.testing.expect(!rig.conn.interest(true).write);
    try std.testing.expectEqualStrings("reply", rig.io.client.output[0..rig.io.client.length]);
    try std.testing.expectEqual(@as(usize, 1), rig.io.client.fins);
    try std.testing.expectEqual(@as(usize, 0), rig.io.backend.fins);
    rig.drive(&config, 1);
    try std.testing.expectEqualSlices(u8, &payload, rig.io.backend.output[0..rig.io.backend.length]);
    try std.testing.expectEqual(@as(usize, 1), rig.io.backend.fins);
    try std.testing.expectEqual(engine.State.closed, rig.conn.state);
}

test "tiny reads never accumulate into splice eligibility; a large opaque read qualifies" {
    if (!relay_pipe.enabled) return error.SkipZigTest;
    var config = try testConfig();
    defer config.deinit(std.testing.allocator);
    var rig: Rig = .{};
    rig.relay();
    var forward: [65536]u8 = undefined;
    rig.conn.to_backend.buffer = .{ .data = &forward };
    const payload: [32768]u8 = @splat(0xa7);
    rig.io.client.input = &payload;
    rig.io.client.max_read = 64;
    rig.drive(&config, 12);
    try std.testing.expectEqual(payload.len, rig.io.backend.length);
    try std.testing.expect(!rig.conn.splice_eligible);
    try std.testing.expectEqual(@as(usize, 0), rig.io.open_attempts);
    rig.io.client.offset = 0;
    rig.io.client.max_read = 16384;
    rig.drive(&config, 1);
    try std.testing.expect(rig.conn.splice_eligible);
    try std.testing.expectEqual(@as(usize, 1), rig.io.open_attempts);
    rig.drive(&config, 1);
    try std.testing.expectEqual(@as(usize, 1), rig.io.open_attempts);
}

test "shared pipes spill before yielding and never mix two connections" {
    if (!relay_pipe.enabled) return error.SkipZigTest;
    var config = try testConfig();
    defer config.deinit(std.testing.allocator);
    var rig: Rig = .{};
    rig.relay();
    rig.conn.splice_eligible = true;
    rig.io.use_pipes = true;
    const first = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    rig.io.client.input = first;
    rig.io.backend.blocked = true;
    rig.drive(&config, 1);
    const first_offset = rig.io.client.offset;
    try std.testing.expectEqual(@as(usize, 32), rig.conn.to_backend.buffer.len);
    try std.testing.expectEqual(@as(usize, 0), rig.io.pipes[0].len);
    try std.testing.expectEqual(@as(usize, 0), rig.io.pipes[1].len);
    try std.testing.expect(rig.conn.to_backend.pipe == null and rig.conn.to_client.pipe == null);
    var stage: [64]u8 = undefined;
    var forward: [32]u8 = undefined;
    var reverse: [32]u8 = undefined;
    var second = engine.Connection.init(1, &stage, &forward, &reverse, 0);
    second.stage = null;
    second.backend = 2;
    second.state = .relaying;
    second.splice_eligible = true;
    rig.io.backend.blocked = false;
    rig.io.client.input = "another connection";
    rig.io.client.offset = 0;
    second.drive(&rig.io, &config, 1, true, &rig.counts);
    try std.testing.expectEqualStrings("another connection", rig.io.backend.output[0..rig.io.backend.length]);
    second.close(.stopping);
    second.assertPipesReturned();
    try std.testing.expectEqual(@as(usize, 0), rig.io.pipe_fds_closed);
    rig.io.client.input = first;
    rig.io.client.offset = first_offset;
    rig.io.client.eof = true;
    rig.io.backend.max_write = 3;
    rig.io.backend.input = "reverse after FIN";
    rig.io.backend.eof = true;
    rig.drive(&config, 10);
    try std.testing.expectEqualStrings("another connection" ++ first, rig.io.backend.output[0..rig.io.backend.length]);
    try std.testing.expectEqualStrings("reverse after FIN", rig.io.client.output[0..rig.io.client.length]);
    try std.testing.expectEqual(engine.State.closed, rig.conn.state);
    try std.testing.expectEqual(engine.CloseReason.complete, rig.conn.reason);
    try std.testing.expectEqual(@as(usize, 1), rig.io.client.fins);
    try std.testing.expectEqual(@as(usize, 1), rig.io.backend.fins);
    try std.testing.expectEqual(@as(usize, 1), rig.io.open_attempts);
    rig.conn.assertPipesReturned();
    rig.io.disableSharedPipes();
    rig.io.disableSharedPipes();
    try std.testing.expectEqual(@as(usize, 4), rig.io.pipe_fds_closed);
}

test "shared pipe reset discards pending data; reclamation failure disables the fast path" {
    if (!relay_pipe.enabled) return error.SkipZigTest;
    var config = try testConfig();
    defer config.deinit(std.testing.allocator);
    for (0..3) |fault| {
        const reclaim_failure = fault == 2;
        var rig: Rig = .{};
        rig.relay();
        rig.conn.splice_eligible = true;
        rig.io.use_pipes = true;
        rig.io.client.input = "pending bytes";
        if (reclaim_failure) {
            rig.io.backend.blocked = true;
            rig.io.reclaim_error = .BADF;
        } else rig.io.backend.write_error = if (fault == 0) .CONNRESET else .PIPE;
        rig.drive(&config, 1);
        try std.testing.expectEqual(engine.State.closed, rig.conn.state);
        try std.testing.expectEqual(@as(usize, 0), rig.io.pipes[0].len);
        try std.testing.expectEqual(@as(usize, 0), rig.io.pipes[1].len);
        try expectIoEvent(rig.counts, if (reclaim_failure) "client_read_errors" else "backend_write_errors", if (reclaim_failure) "other_io_errors" else if (fault == 0) "connection_resets" else "broken_pipes");
        try std.testing.expectEqual(@as(usize, if (reclaim_failure) 4 else 0), rig.io.pipe_fds_closed);
    }
}

test "short-message phase returns to buffering and a later large read restores splice" {
    if (!relay_pipe.enabled) return error.SkipZigTest;
    var config = try testConfig();
    defer config.deinit(std.testing.allocator);
    var rig: Rig = .{};
    rig.relay();
    rig.conn.splice_eligible = true;
    rig.io.use_pipes = true;
    const tiny_phase: [2240]u8 = @splat(0x31);
    rig.io.pipe_capacity = 65536;
    rig.io.client.input = &tiny_phase;
    rig.drive(&config, 1);
    try std.testing.expectEqual(@as(u8, 32), rig.conn.short_reads);
    const splice_reads = rig.io.splice_reads;
    rig.drive(&config, 2);
    try std.testing.expect(!rig.conn.splice_eligible);
    try std.testing.expectEqual(splice_reads, rig.io.splice_reads);
    try std.testing.expectEqualSlices(u8, &tiny_phase, rig.io.backend.output[0..rig.io.backend.length]);
    try std.testing.expectEqual(@as(usize, 0), rig.io.pipe_fds_closed);
    var ring: [65536]u8 = undefined;
    rig.conn.to_backend.buffer = .{ .data = &ring };
    const bulk_phase: [32768]u8 = @splat(0xc4);
    rig.io.client.input = &bulk_phase;
    rig.io.client.offset = 0;
    rig.io.backend.length = 0;
    rig.io.client.max_read = 16384;
    rig.io.max_splice_read = 65536;
    rig.drive(&config, 8);
    try std.testing.expect(rig.conn.splice_eligible);
    try std.testing.expect(rig.io.splice_reads > splice_reads);
    try std.testing.expectEqualSlices(u8, &bulk_phase, rig.io.backend.output[0..rig.io.backend.length]);
    try std.testing.expectEqual(@as(usize, 1), rig.io.open_attempts);
}

test "shared source EAGAIN and page-slot pressure retain independent FIN halves" {
    if (!relay_pipe.enabled) return error.SkipZigTest;
    var config = try testConfig();
    defer config.deinit(std.testing.allocator);
    var rig: Rig = .{};
    rig.relay();
    rig.conn.splice_eligible = true;
    rig.io.use_pipes = true;
    rig.io.pipe_read_blocked = true;
    rig.io.backend.input = "reply before FIN";
    rig.io.backend.eof = true;
    rig.drive(&config, 1);
    try std.testing.expect(rig.conn.interest(true).read);
    try std.testing.expectEqual(@as(usize, 0), rig.io.client.fins);
    rig.io.pipe_read_blocked = false;
    rig.io.pipe_page_full = true;
    rig.io.max_splice_read = 8;
    rig.io.client.blocked = true;
    rig.drive(&config, 1);
    try std.testing.expectEqual(@as(usize, 8), rig.conn.to_client.buffer.len);
    try std.testing.expectEqual(@as(usize, 0), rig.io.pipes[1].len);
    try std.testing.expectEqual(@as(usize, 0), rig.io.client.fins);
    rig.io.client.blocked = false;
    rig.io.client.max_write = 1;
    rig.drive(&config, 3);
    try std.testing.expectEqualStrings("reply before FIN", rig.io.client.output[0..rig.io.client.length]);
    try std.testing.expectEqual(@as(usize, 1), rig.io.client.fins);
    try std.testing.expectEqual(engine.State.relaying, rig.conn.state);
    rig.io.client.input = "sending after the reply half closed";
    rig.io.client.eof = true;
    rig.drive(&config, 3);
    try std.testing.expectEqualSlices(u8, rig.io.client.input, rig.io.backend.output[0..rig.io.backend.length]);
    try std.testing.expectEqual(engine.State.closed, rig.conn.state);
    try std.testing.expectEqual(@as(u64, 0), rig.counts.io_errors);
}

test "spilled ring debt drains before splice resumes in the same callback" {
    if (!relay_pipe.enabled) return error.SkipZigTest;
    var config = try testConfig();
    defer config.deinit(std.testing.allocator);
    var rig: Rig = .{};
    rig.relay();
    rig.conn.splice_eligible = true;
    rig.io.use_pipes = true;
    rig.io.client.input = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    rig.io.client.eof = true;
    rig.io.backend.blocked = true;
    rig.drive(&config, 1);
    try std.testing.expectEqual(@as(usize, 32), rig.conn.to_backend.buffer.len);
    const before = rig.io.splice_reads;
    rig.io.backend.blocked = false;
    rig.drive(&config, 1);
    try std.testing.expect(rig.io.splice_reads > before);
    try std.testing.expectEqualSlices(u8, rig.io.client.input, rig.io.backend.output[0..rig.io.backend.length]);
    try std.testing.expectEqual(@as(usize, 1), rig.io.backend.fins);
    try std.testing.expectEqual(@as(usize, 0), rig.conn.to_backend.buffer.len);
    try std.testing.expectEqual(@as(usize, 0), rig.io.pipes[0].len);
}

test "uneven large splice reads stop at the byte quantum without forcing a copied tail" {
    if (!relay_pipe.enabled) return error.SkipZigTest;
    var config = try testConfig();
    defer config.deinit(std.testing.allocator);
    var rig: Rig = .{};
    rig.relay();
    rig.conn.splice_eligible = true;
    rig.io.use_pipes = true;
    rig.io.pipe_capacity = 65536;
    rig.io.max_splice_read = 65536;
    rig.io.client.max_read = 31713;
    var forward: [65536]u8 = undefined;
    rig.conn.to_backend.buffer = .{ .data = &forward };
    const payload: [engine.relay_byte_budget + 63]u8 = @splat(0x9b);
    rig.io.client.input = &payload;
    rig.io.client.eof = true;
    rig.io.backend.input = "independent reply";
    rig.io.backend.eof = true;
    rig.now = 3;
    rig.drive(&config, 1);
    try std.testing.expectEqual(@as(usize, engine.relay_byte_budget), rig.io.backend.length);
    try std.testing.expectEqual(@as(usize, engine.relay_byte_budget), rig.io.client.offset);
    try std.testing.expectEqual(@as(usize, 0), rig.conn.to_backend.buffer.len);
    try std.testing.expectEqual(@as(usize, 0), rig.io.pipes[0].len);
    try std.testing.expectEqual(@as(usize, 1), rig.io.client.fins);
    rig.drive(&config, 1);
    try std.testing.expectEqualSlices(u8, &payload, rig.io.backend.output[0..rig.io.backend.length]);
    try std.testing.expectEqual(engine.State.closed, rig.conn.state);
    try std.testing.expectEqual(@as(u64, 0), rig.counts.io_errors);
}

test "pipe allocation fallback is once per serving owner; prefix debt cannot be overtaken" {
    if (!relay_pipe.enabled) return error.SkipZigTest;
    var config = try testConfig();
    defer config.deinit(std.testing.allocator);
    var rig: Rig = .{};
    rig.init(.{});
    rig.conn.splice_eligible = true;
    rig.io.use_pipes = true;
    rig.io.backend.blocked = true;
    rig.drive(&config, 1);
    try std.testing.expect(rig.conn.stage != null);
    try std.testing.expectEqual(@as(usize, 0), rig.io.backend.length);
    try std.testing.expectEqual(@as(usize, 0), rig.io.pipes[0].len);
    rig.io.backend.blocked = false;
    rig.io.backend.max_write = 2;
    rig.drive(&config, 1);
    try std.testing.expectEqualSlices(u8, rig.io.client.input, rig.io.backend.output[0..rig.io.backend.length]);
    try std.testing.expectEqual(@as(usize, 1), rig.io.open_attempts);
    rig.conn.assertPipesReturned();
    rig.io.disableSharedPipes();
    rig.relay();
    rig.conn.splice_eligible = true;
    rig.io.client.offset = 0;
    rig.io.client.input = "fallback still forwards";
    rig.io.backend.length = 0;
    rig.drive(&config, 3);
    try std.testing.expectEqual(@as(usize, 1), rig.io.open_attempts);
    try std.testing.expectEqualStrings("fallback still forwards", rig.io.backend.output[0..rig.io.backend.length]);
}

test "shared spilled FIN waits for debt and NOTCONN probes the actual destination half" {
    if (!relay_pipe.enabled) return error.SkipZigTest;
    var config = try testConfig();
    defer config.deinit(std.testing.allocator);
    for ([_]bool{ false, true }) |reverse| for ([_]bool{ false, true }) |reset| {
        var rig: Rig = .{};
        rig.relay();
        rig.conn.splice_eligible = true;
        rig.io.use_pipes = true;
        const source = if (reverse) &rig.io.backend else &rig.io.client;
        const target = if (reverse) &rig.io.client else &rig.io.backend;
        const direction = if (reverse) &rig.conn.to_client else &rig.conn.to_backend;
        source.input = "debt before FIN";
        source.eof = true;
        target.input = "opposite";
        target.eof = true;
        target.blocked = true;
        target.max_write = 2;
        target.shutdown_error = .NOTCONN;
        if (reset) target.socket_error = .CONNRESET;
        rig.drive(&config, 1);
        try std.testing.expectEqual(source.input.len, direction.buffer.len);
        try std.testing.expectEqual(@as(usize, 0), target.fins);
        target.blocked = false;
        rig.drive(&config, 2);
        try std.testing.expectEqualSlices(u8, source.input, target.output[0..target.length]);
        try std.testing.expectEqual(@as(usize, 1), target.fins);
        try std.testing.expectEqual(@as(usize, 1), target.error_checks);
        try std.testing.expectEqual(engine.State.closed, rig.conn.state);
        if (reset) {
            try expectIoEvent(rig.counts, if (reverse) "client_socket_errors" else "backend_socket_errors", "connection_resets");
        } else {
            try std.testing.expectEqual(engine.CloseReason.complete, rig.conn.reason);
            try std.testing.expectEqual(@as(u64, 0), rig.counts.io_errors);
        }
        try std.testing.expectEqual(@as(usize, 0), rig.io.pipes[0].len);
        try std.testing.expectEqual(@as(usize, 0), rig.io.pipes[1].len);
    };
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
        rig.conn.expire(&rig.io, &config, 4999, &rig.counts);
        try std.testing.expect(rig.conn.state != .closed);
        rig.conn.expire(&rig.io, &config, 5000, &rig.counts);
        try std.testing.expectEqual(engine.CloseReason.timeout, rig.conn.reason);
        rig.conn.expire(&rig.io, &config, 6000, &rig.counts);
        try std.testing.expectEqual(@as(u64, 1), rig.counts.timeouts);
    }
    var idle: Rig = .{};
    idle.relay();
    idle.conn.expire(&idle.io, &config, 300000, &idle.counts);
    try std.testing.expectEqual(engine.CloseReason.timeout, idle.conn.reason);
    idle.relay();
    config.raw.value.idle_timeout_ms = 0;
    idle.conn.expire(&idle.io, &config, 9_000_000, &idle.counts);
    try std.testing.expectEqual(engine.State.relaying, idle.conn.state);
}

test "unknown and missing SNI reject without fallback and select fallback when configured" {
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
    for ([_]?[]const u8{ "example.org", null }) |name| {
        var rig: Rig = .{};
        rig.init(.{ .name = name });
        rig.drive(&config, 1);
        try std.testing.expectEqual(@as(usize, 1), rig.io.connects);
        try std.testing.expect(std.meta.eql(config.fallback.?, rig.io.destination.?));
        try std.testing.expectEqual(@as(u64, 1), rig.counts.fallback_routed);
        try std.testing.expectEqualSlices(u8, rig.io.client.input, rig.io.backend.output[0..rig.io.backend.length]);
    }
}

test "malformed framing, non-TLS, record limits and partial EOF preserve fallback input" {
    var config = try testConfig();
    defer config.deinit(std.testing.allocator);
    for ([_]bool{ false, true }) |enabled| for (0..7) |case| {
        config.fallback = if (enabled) try Address.parseLiteral("127.0.0.1:9444") else null;
        var rig: Rig = .{};
        rig.init(.{});
        switch (case) {
            0 => rig.input[0] = 23,
            1 => rig.input[5] = 2,
            2 => rig.io.client.input = "GET / HTTP/1.1\r\n\r\n",
            3 => rig.io.client.input = "\x16\x03\x01\xff\xff",
            4 => rig.io.client.input = fixture.make(&rig.input, .{ .fragment_bytes = 1 }),
            5 => rig.io.client.input = fixture.make(&rig.input, .{ .duplicate_sni = true }),
            6 => {
                rig.io.client.input = rig.input[0..15];
                rig.io.client.eof = true;
            },
            else => unreachable,
        }
        const wire = rig.io.client.input;
        rig.io.backend.max_write = 3;
        rig.drive(&config, 16);
        try std.testing.expectEqual(@as(u64, 1), rig.counts.invalid_client_hello);
        try std.testing.expectEqual(@as(u64, if (enabled) 1 else 0), rig.counts.fallback_routed);
        if (enabled) {
            try std.testing.expectEqualSlices(u8, wire, rig.io.backend.output[0..rig.io.backend.length]);
            try std.testing.expectEqual(case == 6, rig.conn.to_backend.fin);
            try std.testing.expectEqual(@as(u64, wire.len), rig.counts.bytes_client_to_backend);
        } else {
            try std.testing.expectEqual(engine.CloseReason.invalid_hello, rig.conn.reason);
            try std.testing.expectEqual(@as(usize, 0), rig.io.connects);
        }
    };
}

test "over-limit wire input uses only the bounded inspection prefix then the ordinary relay" {
    var config = try testConfig();
    defer config.deinit(std.testing.allocator);
    config.fallback = try Address.parseLiteral("127.0.0.1:9444");
    config.raw.value.fallback_proxy_protocol = 2;
    var input: [65541]u8 = undefined;
    const wire = fixture.make(&input, .{ .handshake_bytes = 65516, .fragment_bytes = 16000 });
    for ([_]bool{ false, true }) |ipv6| {
        var rig: Rig = .{};
        rig.init(.{});
        if (ipv6) {
            rig.io.peer = try Address.parseLiteral("[2001:db8::9]:4660");
            rig.io.local = try Address.parseLiteral("[2001:db8::7]:443");
        }
        const header_bytes: usize = if (ipv6) 52 else 28;
        rig.io.client.input = wire;
        rig.io.backend.blocked = true;
        rig.drive(&config, 1);
        try std.testing.expectEqual(@as(usize, 65536), rig.io.client.offset);
        try std.testing.expectEqual(65536 + header_bytes, rig.conn.stage_len);
        try std.testing.expectEqual(@as(u64, 1), rig.counts.invalid_client_hello);
        rig.io.backend.blocked = false;
        rig.drive(&config, 4);
        try std.testing.expect(rig.conn.stage == null);
        try std.testing.expectEqualSlices(u8, wire, rig.io.backend.output[header_bytes..rig.io.backend.length]);
        try std.testing.expectEqual(@as(u64, wire.len), rig.counts.bytes_client_to_backend);
    }
}

test "partial hello deadline selects bounded fallback once, empty EOF and timeout never connect" {
    var config = try testConfig();
    defer config.deinit(std.testing.allocator);
    config.fallback = try Address.parseLiteral("127.0.0.1:9444");
    config.raw.value.idle_timeout_ms = 0;
    for ([_]bool{ false, true }) |partial| for ([_]bool{ false, true }) |eof| {
        var rig: Rig = .{};
        rig.init(.{});
        rig.io.client.input = rig.input[0..if (partial) @as(usize, 15) else 0];
        rig.io.client.eof = eof;
        rig.io.backend.blocked = true;
        rig.drive(&config, 1);
        rig.now = 5000;
        rig.drive(&config, 1);
        if (partial) {
            try std.testing.expectEqual(@as(usize, 1), rig.io.connects);
            try std.testing.expectEqual(@as(u64, 1), rig.counts.fallback_routed);
            try std.testing.expectEqual(@as(u64, if (eof) 0 else 1), rig.counts.timeouts);
            try std.testing.expectEqual(@as(u64, if (eof) 1 else 0), rig.counts.invalid_client_hello);
            try std.testing.expect(!rig.conn.to_backend.fin);
            try std.testing.expectEqual(@as(?u64, if (eof) 5001 else 10000), rig.conn.deadline(config.raw.value));
            rig.now = if (eof) 5001 else 10000;
            rig.drive(&config, 1);
            try std.testing.expectEqual(engine.CloseReason.timeout, rig.conn.reason);
            try std.testing.expectEqual(@as(usize, 1), rig.io.connects);
        } else {
            try std.testing.expectEqual(@as(usize, 0), rig.io.connects);
            try std.testing.expectEqual(if (eof) engine.CloseReason.complete else .timeout, rig.conn.reason);
            try std.testing.expectEqual(@as(u64, 0), rig.counts.invalid_client_hello);
        }
    };
}

test "fallback does not hide transport errors or retry failed selected backends" {
    var config = try testConfig();
    defer config.deinit(std.testing.allocator);
    config.fallback = try Address.parseLiteral("127.0.0.1:9444");
    for (0..3) |case| {
        var rig: Rig = .{};
        rig.init(.{});
        rig.io.client.input = rig.input[0..15];
        if (case == 0) rig.io.client.read_error = .CONNRESET;
        // Pending socket failure at the partial hello deadline is fatal too.
        if (case != 0) {
            rig.io.client.socket_error = .CONNRESET;
            if (case == 1) rig.conn.checkSocketError(&rig.io, false, &rig.counts);
        }
        rig.drive(&config, 1);
        rig.now = 5000;
        rig.drive(&config, 1);
        try std.testing.expectEqual(engine.CloseReason.io_error, rig.conn.reason);
        try std.testing.expectEqual(@as(usize, 0), rig.io.connects);
        try expectIoConsistent(rig.counts);
    }
    for ([_]bool{ false, true }) |unknown| for ([_]bool{ false, true }) |async_connect| {
        var rig: Rig = .{};
        rig.init(.{ .name = if (unknown) "example.org" else "example.com" });
        rig.io.immediate = !async_connect;
        rig.io.connect_failed = !async_connect;
        rig.io.finish_failed = async_connect;
        rig.drive(&config, 1);
        try std.testing.expectEqual(engine.CloseReason.connect_failed, rig.conn.reason);
        try std.testing.expectEqual(@as(usize, 1), rig.io.connects);
        try std.testing.expectEqual(@as(u64, if (unknown) 1 else 0), rig.counts.fallback_routed);
        try std.testing.expect(std.meta.eql(if (unknown) config.fallback.? else config.routes[0].backend, rig.io.destination.?));
    };
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

test "known SNI remains raw even when fallback shares its endpoint and PROXY v2 is enabled" {
    var config = try testConfig();
    defer config.deinit(std.testing.allocator);
    config.fallback = config.routes[0].backend;
    config.raw.value.fallback_proxy_protocol = 2;
    var rig: Rig = .{};
    rig.init(.{});
    rig.io.proxy_error = .CONNRESET;
    rig.drive(&config, 1);
    try std.testing.expectEqual(@as(usize, 0), rig.io.proxy_queries);
    try std.testing.expectEqual(@as(u64, 0), rig.counts.fallback_routed);
    try std.testing.expectEqual(@as(u8, 0), rig.conn.proxy_header_remaining);
    try std.testing.expectEqualSlices(u8, rig.io.client.input, rig.io.backend.output[0..rig.io.backend.length]);
    try std.testing.expectEqual(@as(u64, rig.io.client.input.len), rig.counts.bytes_client_to_backend);
}

test "PROXY debt precedes partial EOF prefix across async connect, EAGAIN, partial sends and independent reply" {
    var config = try testConfig();
    defer config.deinit(std.testing.allocator);
    config.fallback = try Address.parseLiteral("127.0.0.1:9444");
    config.raw.value.fallback_proxy_protocol = 2;
    var rig: Rig = .{};
    rig.init(.{});
    const prefix = rig.input[0..15];
    rig.io.client.input = prefix;
    rig.io.client.eof = true;
    rig.io.immediate = false;
    rig.io.backend.blocked = true;
    rig.conn.drive(&rig.io, &config, 1, false, &rig.counts);
    try std.testing.expectEqual(engine.State.connecting, rig.conn.state);
    try std.testing.expectEqual(@as(usize, 0), rig.io.completions);
    try std.testing.expectEqual(@as(usize, 0), rig.io.backend.length);
    rig.conn.drive(&rig.io, &config, 2, false, &rig.counts);
    try std.testing.expectEqual(@as(usize, 0), rig.io.completions);
    rig.io.backend.input = "independent reply";
    rig.io.backend.eof = true;
    rig.drive(&config, 1);
    try std.testing.expectEqual(@as(usize, 1), rig.io.completions);
    try std.testing.expectEqualStrings("independent reply", rig.io.client.output[0..rig.io.client.length]);
    try std.testing.expect(rig.conn.to_client.fin);
    try std.testing.expect(!rig.conn.to_backend.fin);
    try std.testing.expect(rig.conn.interest(true).write);
    try std.testing.expect(!rig.conn.interest(false).read);
    rig.io.backend.blocked = false;
    rig.io.backend.max_write = 3;
    rig.io.backend.writes_left = 1;
    rig.drive(&config, 1);
    try std.testing.expectEqual(@as(usize, 3), rig.conn.stage_sent);
    try std.testing.expectEqual(@as(u64, 0), rig.counts.bytes_client_to_backend);
    try std.testing.expectEqual(@as(usize, 0), rig.io.backend.fins);
    rig.io.backend.max_write = 26;
    rig.io.backend.writes_left = 1;
    rig.drive(&config, 1);
    try std.testing.expectEqual(@as(usize, 29), rig.conn.stage_sent);
    try std.testing.expectEqual(@as(u64, 1), rig.counts.bytes_client_to_backend);
    try std.testing.expectEqual(@as(usize, 0), rig.io.backend.fins);
    rig.io.backend.max_write = 2;
    rig.io.backend.writes_left = null;
    rig.drive(&config, 1);
    try std.testing.expectEqualSlices(u8, "\r\n\r\n\x00\r\nQUIT\n\x21\x11\x00\x0c\xc0\x00\x02\x09\xc6\x33\x64\x07\x12\x34\x01\xbb", rig.io.backend.output[0..28]);
    try std.testing.expectEqualSlices(u8, prefix, rig.io.backend.output[28..rig.io.backend.length]);
    try std.testing.expectEqual(@as(u64, prefix.len), rig.counts.bytes_client_to_backend);
    try std.testing.expectEqual(@as(usize, 1), rig.io.proxy_queries);
    try std.testing.expectEqual(@as(usize, 1), rig.io.backend.fins);
    try std.testing.expect(rig.conn.stage == null);
    try std.testing.expectEqual(engine.CloseReason.complete, rig.conn.reason);
    try std.testing.expectEqual(engine.State.closed, rig.conn.state);
}

test "partial hello timeout with PROXY v2 sends its bytes once and permits later client data" {
    var config = try testConfig();
    defer config.deinit(std.testing.allocator);
    config.fallback = try Address.parseLiteral("127.0.0.1:9444");
    config.raw.value.fallback_proxy_protocol = 2;
    var rig: Rig = .{};
    rig.init(.{});
    const prefix = rig.input[0..15];
    rig.io.client.input = prefix;
    rig.drive(&config, 1);
    rig.now = 5000;
    rig.drive(&config, 1);
    try std.testing.expectEqualSlices(u8, prefix, rig.io.backend.output[28..rig.io.backend.length]);
    rig.io.client.input = "later opaque bytes";
    rig.io.client.offset = 0;
    rig.drive(&config, 4);
    try std.testing.expectEqualSlices(u8, prefix, rig.io.backend.output[28..][0..prefix.len]);
    try std.testing.expectEqualStrings("later opaque bytes", rig.io.backend.output[28 + prefix.len .. rig.io.backend.length]);
    try std.testing.expectEqual(@as(u64, prefix.len + rig.io.client.input.len), rig.counts.bytes_client_to_backend);
    try std.testing.expectEqual(@as(u64, 1), rig.counts.timeouts);
    try std.testing.expectEqual(@as(u64, 0), rig.counts.invalid_client_hello);
    try std.testing.expectEqual(@as(usize, 1), rig.io.proxy_queries);
    try std.testing.expectEqual(@as(usize, 1), rig.io.connects);
}

test "PROXY metadata errors and header write reset close once without retry or stale pooled state" {
    var config = try testConfig();
    defer config.deinit(std.testing.allocator);
    config.fallback = try Address.parseLiteral("127.0.0.1:9444");
    config.raw.value.fallback_proxy_protocol = 2;
    for (0..4) |fault| {
        var rig: Rig = .{};
        rig.init(.{ .name = "example.org" });
        switch (fault) {
            0 => rig.io.proxy_error = .BADF,
            1 => rig.io.proxy_unsupported = true,
            2 => rig.io.local = try Address.parseLiteral("[2001:db8::7]:443"),
            3 => {
                rig.io.backend.max_write = 3;
                rig.io.backend.writes_left = 1;
            },
            else => unreachable,
        }
        rig.drive(&config, 1);
        if (fault == 3) {
            rig.io.backend.write_error = .CONNRESET;
            rig.drive(&config, 1);
            try expectIoEvent(rig.counts, "backend_write_errors", "connection_resets");
            try std.testing.expectEqual(@as(usize, 3), rig.io.backend.length);
        } else {
            try std.testing.expectEqual(@as(usize, 0), rig.io.connects);
            if (fault == 0) try expectIoEvent(rig.counts, "client_socket_errors", "other_io_errors") else {
                try std.testing.expectEqual(@as(u64, 1), rig.counts.rejected);
                try std.testing.expectEqual(engine.CloseReason.proxy_metadata_failed, rig.conn.reason);
                try std.testing.expectEqual(@as(u64, 0), rig.counts.io_errors);
            }
        }
        try std.testing.expectEqual(engine.State.closed, rig.conn.state);
        try std.testing.expectEqual(@as(u64, 0), rig.counts.bytes_client_to_backend);
        rig.io = .{};
        rig.counts = .{};
        rig.init(.{});
        try std.testing.expectEqual(@as(u8, 0), rig.conn.proxy_header_remaining);
        try std.testing.expectEqual(@as(usize, 0), rig.conn.stage_sent);
        rig.drive(&config, 1);
        try std.testing.expectEqual(@as(usize, 0), rig.io.proxy_queries);
        try std.testing.expectEqualSlices(u8, rig.io.client.input, rig.io.backend.output[0..rig.io.backend.length]);
    }
}

test "PROXY connect and blocked prefix deadlines stay absolute with established idle disabled" {
    var config = try testConfig();
    defer config.deinit(std.testing.allocator);
    config.fallback = try Address.parseLiteral("127.0.0.1:9444");
    config.raw.value.fallback_proxy_protocol = 2;
    config.raw.value.connect_timeout_ms = 250;
    config.raw.value.idle_timeout_ms = 0;
    for ([_]bool{ false, true }) |immediate| {
        var rig: Rig = .{};
        rig.init(.{ .name = "example.org" });
        rig.io.immediate = immediate;
        rig.io.backend.blocked = true;
        rig.conn.drive(&rig.io, &config, 1, false, &rig.counts);
        try std.testing.expect(rig.conn.stage != null);
        rig.conn.drive(&rig.io, &config, 251, false, &rig.counts);
        try std.testing.expectEqual(engine.CloseReason.timeout, rig.conn.reason);
        try std.testing.expectEqual(@as(usize, 1), rig.io.connects);
        try std.testing.expectEqual(@as(usize, 1), rig.io.proxy_queries);
        try std.testing.expectEqual(@as(u64, 1), rig.counts.timeouts);
        try std.testing.expectEqual(@as(u64, 0), rig.counts.io_errors);
        try std.testing.expectEqual(@as(usize, 0), rig.io.backend.length);
        try std.testing.expectEqual(@as(usize, 0), rig.io.backend.fins);
    }
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
        .{ .err = @fromBackingInt(@as(u16, 4090)), .cause = "other_io_errors" },
    };
    for ([_]bool{ false, true }) |backend| for (cases) |case| {
        var rig: Rig = .{};
        rig.relay();
        (if (backend) &rig.io.backend else &rig.io.client).read_error = case.err;
        rig.drive(&config, 5);
        try std.testing.expectEqual(engine.CloseReason.io_error, rig.conn.reason);
        try expectIoEvent(rig.counts, if (backend) "backend_read_errors" else "client_read_errors", case.cause);
        const detail = rig.conn.io_failure.?;
        try std.testing.expectEqual(if (backend) outcome.Side.backend else outcome.Side.client, detail.side);
        try std.testing.expectEqual(outcome.Operation.read, detail.operation);
        try std.testing.expectEqual(case.err, detail.failure.errno);
        try std.testing.expectEqual(@as(u64, if (std.mem.eql(u8, case.cause, "other_io_errors")) @backingInt(case.err) else 0), rig.counts.last_other_io_errno);
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
    for ([_]outcome.Errno{ .CONNRESET, .PIPE, .NOTCONN, .CONNABORTED, .TIMEDOUT, .NETUNREACH, .BADF, @fromBackingInt(@as(u16, 4090)) }, 0..) |err, index| {
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
