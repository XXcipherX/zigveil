//! The production state machine. Only socket operations are supplied by tests.
const std = @import("std");
const hello = @import("client_hello.zig");
const config_mod = @import("config.zig");
const Config = config_mod.Config;
const Counters = @import("counters.zig").Counters;
const Buffer = @import("buffer.zig").Buffer;
const outcome = @import("io_result.zig");
const metrics = @import("metrics.zig");
const relay_pipe = @import("relay_pipe.zig");
const proxy_protocol = @import("proxy_protocol.zig");
pub const relay_byte_budget = 262144;
const relay_call_budget = 128;
const bulk_read_bytes = 16384;
const short_read_bytes = 1024;
const short_read_limit = 32;

pub const Connect = struct { fd: i32, complete: bool };
pub const State = enum { hello, connecting, relaying, closed };
pub const CloseReason = enum { complete, invalid_hello, no_route, connect_failed, proxy_metadata_failed, io_error, timeout, stopping };
pub const Direction = struct {
    buffer: Buffer,
    eof: bool = false,
    fin: bool = false,
    pipe: if (relay_pipe.enabled) ?relay_pipe.Borrowed else void = if (relay_pipe.enabled) null else {},

    fn queued(self: *const Direction) usize {
        if (relay_pipe.enabled) if (self.pipe) |pipe| return pipe.pending;
        return self.buffer.len;
    }

    fn canRead(self: *const Direction) bool {
        if (self.eof) return false;
        if (relay_pipe.enabled) if (self.pipe) |pipe| return !pipe.read_paused and pipe.pending < pipe.handle.capacity;
        return self.buffer.len < self.buffer.data.len;
    }
};
pub const Interest = struct { read: bool = false, write: bool = false };
pub const IoFailure = struct { side: outcome.Side, operation: outcome.Operation, failure: outcome.Failure };

pub const Connection = struct {
    client: i32,
    backend: i32 = -1,
    state: State = .hello,
    reason: CloseReason = .complete,
    io_failure: ?IoFailure = null,
    stage: ?[]u8,
    stage_len: usize = 0,
    stage_sent: usize = 0,
    proxy_header_remaining: u8 = 0,
    to_backend: Direction,
    to_client: Direction,
    entered_ms: u64,
    activity_ms: u64,
    splice_eligible: if (relay_pipe.enabled) bool else void = if (relay_pipe.enabled) false else {},
    pipe_failed: if (relay_pipe.enabled) bool else void = if (relay_pipe.enabled) false else {},
    short_reads: if (relay_pipe.enabled) u8 else void = if (relay_pipe.enabled) 0 else {},

    pub fn init(client: i32, stage: []u8, forward: []u8, reverse: []u8, now: u64) Connection {
        return .{
            .client = client,
            .stage = stage,
            .to_backend = .{ .buffer = .{ .data = forward } },
            .to_client = .{ .buffer = .{ .data = reverse } },
            .entered_ms = now,
            .activity_ms = now,
        };
    }

    pub fn close(self: *Connection, reason: CloseReason) void {
        self.reason = reason;
        self.state = .closed;
    }

    pub fn deadline(self: *const Connection, limits: config_mod.Raw) ?u64 {
        return switch (self.state) {
            .hello => self.entered_ms +| limits.hello_timeout_ms,
            .connecting => self.entered_ms +| limits.connect_timeout_ms,
            .relaying => if (self.stage != null)
                self.entered_ms +| limits.connect_timeout_ms
            else if (limits.idle_timeout_ms != 0)
                self.activity_ms +| limits.idle_timeout_ms
            else
                null,
            .closed => null,
        };
    }

    pub fn expire(self: *Connection, io: anytype, config: *const Config, now: u64, counts: *Counters) void {
        if (self.deadline(config.raw.value)) |when| if (now >= when) {
            if (self.state == .hello and self.stage_len != 0) {
                if (config.fallback) |endpoint| {
                    // A pending transport error must not become routing fallback.
                    self.checkSocketError(io, false, counts);
                    if (self.state == .closed) return;
                    counts.timeouts +%= 1;
                    self.startBackend(io, config, endpoint, true, now, counts);
                    return;
                }
            }
            counts.timeouts +%= 1;
            self.close(.timeout);
        };
    }

    /// backend_ready is set only for the registered connect socket's event.
    /// No completion, callback, or borrowed slice can outlive this invocation.
    pub fn drive(self: *Connection, io: anytype, config: *const Config, now: u64, backend_ready: bool, counts: *Counters) void {
        const before = if (metrics.enabled) io.metrics.progress() else 0;
        const state_before = self.state;
        io.metrics.add("drive_calls", 1);
        defer if (metrics.enabled) {
            if (io.metrics.progress() != before or self.state != state_before)
                io.metrics.add("drive_useful", 1)
            else
                io.metrics.add("drive_no_progress", 1);
        };
        self.expire(io, config, now, counts);
        if (self.state == .closed) return;
        if (self.state == .hello) self.inspect(io, config, now, counts);
        if (self.state == .connecting) {
            if (!backend_ready) return;
            io.finishConnect(self.backend) catch {
                counts.connect_failures +%= 1;
                self.close(.connect_failed);
                return;
            };
            self.state = .relaying;
            self.entered_ms = now;
            self.activity_ms = now;
        }
        if (self.state != .relaying) return;
        if (relay_pipe.enabled and self.short_reads == short_read_limit and
            self.to_backend.queued() == 0 and self.to_client.queued() == 0)
        {
            // A bulk stream can turn into short request/reply traffic. Queued
            // debt still precedes this transition; pipes are already returned.
            self.splice_eligible = false;
            self.short_reads = 0;
            io.metrics.add("pipe_deactivations", 1);
        }
        if (!self.pump(io, &self.to_backend, self.client, self.backend, true, now, counts) or self.state == .closed) return;
        if (!self.pump(io, &self.to_client, self.backend, self.client, false, now, counts) or self.state == .closed) return;
        if (self.to_backend.fin and self.to_client.fin) self.close(.complete);
    }

    /// Teardown cannot return pipe debt: each pump must already have reclaimed it.
    pub fn assertPipesReturned(self: *const Connection) void {
        if (relay_pipe.enabled) {
            std.debug.assert(self.to_backend.pipe == null);
            std.debug.assert(self.to_client.pipe == null);
        }
    }

    /// EPOLLERR and drained ENOTCONN use the same probe and accounting path.
    pub fn checkSocketError(self: *Connection, io: anytype, backend: bool, counts: *Counters) void {
        if (self.state == .closed) return;
        switch (io.checkSocketError(if (backend) self.backend else self.client)) {
            .ok => {},
            .err => |err| self.failIo(if (backend) .backend else .client, .socket_error, .{ .errno = err }, counts),
        }
    }

    fn failIo(self: *Connection, side: outcome.Side, operation: outcome.Operation, failure: outcome.Failure, counts: *Counters) void {
        if (self.state == .closed) return;
        counts.recordIo(side, operation, failure);
        self.io_failure = .{ .side = side, .operation = operation, .failure = failure };
        self.close(.io_error);
    }

    fn inspect(self: *Connection, io: anytype, config: *const Config, now: u64, counts: *Counters) void {
        const stage = self.stage.?;
        const inspect_limit = @min(stage.len, hello.max_wire_bytes);
        var calls: usize = 0;
        while (calls < 64) : (calls += 1) {
            if (self.stage_len == inspect_limit) break;
            const n = switch (io.recv(self.client, stage[self.stage_len..inspect_limit])) {
                .ok => |n| n,
                .err => |err| {
                    if (err == .AGAIN) return;
                    self.failIo(.client, .read, .{ .errno = err }, counts);
                    return;
                },
            };
            if (n == 0) {
                if (self.stage_len == 0) {
                    self.close(.complete);
                    return;
                }
                self.to_backend.eof = true;
                break;
            }
            self.stage_len += n;
            switch (hello.parse(stage[0..self.stage_len])) {
                .need_more => continue,
                .invalid => break,
                .ok => |maybe_name| {
                    const name = maybe_name;
                    var destination = config.lookup(if (name) |*value| value else null);
                    const fallback = destination == null;
                    if (destination == null) {
                        if (name == null) counts.missing_sni +%= 1 else counts.unknown_sni +%= 1;
                        destination = config.fallback;
                    }
                    const endpoint = destination orelse {
                        self.close(.no_route);
                        return;
                    };
                    self.startBackend(io, config, endpoint, fallback, now, counts);
                    return;
                },
            }
        }
        // A fairness yield is different from incomplete data at the cap/EOF.
        if (calls == 64 and self.stage_len < inspect_limit) return;
        counts.invalid_client_hello +%= 1;
        if (config.fallback) |endpoint|
            self.startBackend(io, config, endpoint, true, now, counts)
        else
            self.close(.invalid_hello);
    }

    fn startBackend(self: *Connection, io: anytype, config: *const Config, endpoint: config_mod.Address, fallback: bool, now: u64, counts: *Counters) void {
        counts.routed +%= 1;
        if (fallback) {
            counts.fallback_routed +%= 1;
            if (config.raw.value.fallback_proxy_protocol == 2) {
                var header: [proxy_protocol.max_header_bytes]u8 = undefined;
                const n = switch (io.prepareProxyHeader(self.client, &header)) {
                    .ok => |n| n,
                    .err => |err| {
                        self.failIo(.client, .socket_error, .{ .errno = err }, counts);
                        return;
                    },
                    .unsupported => {
                        counts.rejected +%= 1;
                        self.close(.proxy_metadata_failed);
                        return;
                    },
                };
                const stage = self.stage.?;
                std.debug.assert(stage.len - self.stage_len >= n);
                @memmove(stage[n..][0..self.stage_len], stage[0..self.stage_len]);
                @memcpy(stage[0..n], header[0..n]);
                self.stage_len += n;
                self.proxy_header_remaining = n;
            }
        }
        const connecting = io.startConnect(endpoint) catch {
            counts.connect_failures +%= 1;
            self.close(.connect_failed);
            return;
        };
        self.backend = connecting.fd;
        self.entered_ms = now;
        self.activity_ms = now;
        self.state = if (connecting.complete) .relaying else .connecting;
    }

    fn pump(self: *Connection, io: anytype, direction: *Direction, source: i32, target: i32, forward: bool, now: u64, counts: *Counters) bool {
        // Shared pipes belong to this serving owner, never to a connection.
        // A callback may borrow them only while empty, and must return them
        // empty on every path, including blocked writes, fairness and resets.
        defer if (relay_pipe.enabled) self.reclaimPipe(io, direction, forward, counts);
        if (forward) io.metrics.add("pump_forward", 1) else io.metrics.add("pump_reverse", 1);
        var calls: usize = 0;
        var sent: usize = 0;
        var read_blocked = false;
        var write_blocked = false;
        // Drain multiple chunks in one readiness turn, with a fairness quantum.
        // Level-triggered epoll redispatches unfinished ready work.
        while (calls < relay_call_budget and sent < relay_byte_budget) {
            var progress = false;
            const has_prefix = forward and self.stage != null;
            const queued = if (has_prefix) self.stage_len - self.stage_sent else direction.queued();
            if (queued != 0 and !write_blocked) {
                calls += 1;
                const limit = @min(queued, relay_byte_budget - sent);
                const result = if (has_prefix)
                    io.send(target, self.stage.?[self.stage_sent..][0..limit])
                else if (relay_pipe.enabled and direction.pipe != null)
                    io.spliceWrite(direction.pipe.?.handle.fds[0], target, limit)
                else
                    io.send(target, direction.buffer.readable()[0..@min(direction.buffer.readable().len, limit)]);
                const n = switch (result) {
                    .ok => |n| n,
                    .err => |err| blk: {
                        if (err != .AGAIN) {
                            io.metrics.add("pump_fatal", 1);
                            self.failIo(if (forward) .backend else .client, .write, .{ .errno = err }, counts);
                            return false;
                        }
                        write_blocked = true;
                        io.metrics.add("pump_write_again", 1);
                        break :blk 0;
                    },
                };
                if (n == 0 and !write_blocked) {
                    io.metrics.add("pump_fatal", 1);
                    self.failIo(if (forward) .backend else .client, .write, .zero_write, counts);
                    return false;
                }
                if (n != 0) {
                    var payload_bytes = n;
                    if (has_prefix) {
                        if (self.proxy_header_remaining != 0) {
                            const header_bytes = @min(n, self.proxy_header_remaining);
                            self.proxy_header_remaining -= @intCast(header_bytes);
                            payload_bytes -= header_bytes;
                        }
                        self.stage_sent += n;
                        if (self.stage_sent == self.stage_len) {
                            self.stage = null;
                            io.metrics.add("prefix_completed", 1);
                        }
                    } else if (relay_pipe.enabled and direction.pipe != null) {
                        const pipe = &direction.pipe.?;
                        std.debug.assert(n <= pipe.pending);
                        pipe.pending -= n;
                        pipe.read_paused = false;
                    } else {
                        if (metrics.enabled and n == direction.buffer.len) io.metrics.add("ring_drained", 1);
                        direction.buffer.consumed(n);
                    }
                    if (forward) counts.bytes_client_to_backend +%= payload_bytes else counts.bytes_backend_to_client +%= n;
                    self.activity_ms = now;
                    sent += n;
                    progress = true;
                }
            }
            // Do not read ahead after yielding this direction's send budget.
            // LT source readiness resumes the queue, including a pending EOF.
            if ((!forward or self.stage == null) and direction.canRead() and !read_blocked and calls < relay_call_budget and sent < relay_byte_budget and
                (write_blocked or direction.queued() < relay_byte_budget - sent))
            {
                // Drain this direction's ring debt first, then resume splice
                // in the same callback. Variable read sizes and fairness must
                // not strand a bulk stream on the copying path after one spill.
                if (relay_pipe.enabled and self.stage == null and direction.pipe == null and direction.buffer.len == 0 and
                    self.splice_eligible and !self.pipe_failed)
                {
                    if (io.openRelayPipes(direction.buffer.data.len)) |pipes|
                        direction.pipe = .{ .handle = pipes[if (forward) @as(usize, 0) else 1] }
                    else
                        self.pipe_failed = true;
                }
                calls += 1;
                const room = if (write_blocked) std.math.maxInt(usize) else relay_byte_budget - sent - direction.queued();
                const result = if (relay_pipe.enabled and direction.pipe != null)
                    io.spliceRead(source, direction.pipe.?.handle.fds[1], @min(room, direction.pipe.?.handle.capacity - direction.pipe.?.pending))
                else
                    io.recv(source, direction.buffer.writable()[0..@min(room, direction.buffer.writable().len)]);
                const n = switch (result) {
                    .ok => |n| n,
                    .err => |err| blk: {
                        if (err != .AGAIN) {
                            io.metrics.add("pump_fatal", 1);
                            self.failIo(if (forward) .client else .backend, .read, .{ .errno = err }, counts);
                            return false;
                        }
                        read_blocked = true;
                        // Pipe page slots can fill before its byte capacity.
                        // Pending output guarantees redispatch on the target;
                        // retry source input only after a successful drain.
                        if (relay_pipe.enabled and direction.pipe != null and direction.pipe.?.pending != 0)
                            direction.pipe.?.read_paused = true;
                        io.metrics.add("pump_read_again", 1);
                        break :blk 0;
                    },
                };
                if (!read_blocked) {
                    if (n == 0) {
                        direction.eof = true;
                        io.metrics.add("pump_eof", 1);
                    } else if (relay_pipe.enabled and direction.pipe != null) {
                        std.debug.assert(n <= direction.pipe.?.handle.capacity - direction.pipe.?.pending);
                        direction.pipe.?.pending += n;
                        self.short_reads = if (n < short_read_bytes) @min(self.short_reads + 1, short_read_limit) else 0;
                        self.activity_ms = now;
                    } else {
                        // A long sequence of tiny messages is still a small-I/O
                        // workload. Enter the pipe path only after a large
                        // opaque read, never because the ClientHello was large.
                        if (relay_pipe.enabled and n >= bulk_read_bytes) self.splice_eligible = true;
                        if (metrics.enabled and (direction.buffer.head + direction.buffer.len) % direction.buffer.data.len + n == direction.buffer.data.len)
                            io.metrics.add("ring_wrap", 1);
                        direction.buffer.produced(n);
                        if (metrics.enabled and direction.buffer.len == direction.buffer.data.len) io.metrics.add("ring_full", 1);
                        self.activity_ms = now;
                    }
                    progress = true;
                }
            }
            if (direction.eof and direction.queued() == 0 and (!forward or self.stage == null) and !direction.fin) {
                switch (io.shutdown(target)) {
                    .ok => {},
                    .err => |err| {
                        if (err != .NOTCONN) {
                            io.metrics.add("pump_fatal", 1);
                            self.failIo(if (forward) .backend else .client, .shutdown, .{ .errno = err }, counts);
                            return false;
                        }
                        // A closed TCP socket still applies SHUT_WR on Linux.
                        // Preserve any pending reset as a socket-probe failure.
                        self.checkSocketError(io, forward, counts);
                        if (self.state == .closed) return false;
                    },
                }
                direction.fin = true;
            }
            if (!progress) {
                if (metrics.enabled and !direction.eof and !direction.canRead()) io.metrics.add("pump_buffer_full", 1);
                if (!read_blocked and !write_blocked) io.metrics.add("pump_no_work", 1);
                break;
            }
        }
        if (calls >= relay_call_budget) io.metrics.add("pump_call_budget", 1);
        if (sent >= relay_byte_budget) io.metrics.add("pump_byte_budget", 1);
        return true;
    }

    fn reclaimPipe(self: *Connection, io: anytype, direction: *Direction, forward: bool, counts: *Counters) void {
        const pipe = direction.pipe orelse return;
        direction.pipe = null;
        if (pipe.pending == 0) return;
        std.debug.assert(direction.buffer.len == 0 and pipe.pending <= direction.buffer.data.len);
        var copied: usize = 0;
        while (copied < pipe.pending) {
            const n = switch (io.readRelayPipe(pipe.handle.fds[0], direction.buffer.data[copied..pipe.pending])) {
                .ok => |n| n,
                .err => |err| {
                    io.disableSharedPipes();
                    self.failIo(if (forward) .client else .backend, .read, .{ .errno = err }, counts);
                    return;
                },
            };
            if (n == 0) {
                io.disableSharedPipes();
                self.failIo(if (forward) .client else .backend, .read, .{ .errno = .IO }, counts);
                return;
            }
            copied += n;
        }
        io.metrics.add("pipe_spills", 1);
        io.metrics.add("pipe_spill_bytes", copied);
        if (self.state != .closed) direction.buffer = .{ .data = direction.buffer.data, .len = copied };
    }

    pub fn interest(self: *const Connection, backend: bool) Interest {
        return switch (self.state) {
            .hello => if (backend) .{} else .{ .read = true },
            .connecting => if (backend) .{ .write = true } else .{},
            .closed => .{},
            .relaying => if (backend) .{
                .read = self.to_client.canRead(),
                .write = self.stage != null or self.to_backend.queued() != 0,
            } else .{
                .read = self.stage == null and self.to_backend.canRead(),
                .write = self.to_client.queued() != 0,
            },
        };
    }
};
