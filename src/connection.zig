//! The production state machine. Only socket operations are supplied by tests.
const std = @import("std");
const hello = @import("client_hello.zig");
const config_mod = @import("config.zig");
const Config = config_mod.Config;
const Counters = @import("counters.zig").Counters;
const Buffer = @import("buffer.zig").Buffer;
const outcome = @import("io_result.zig");

pub const Connect = struct { fd: i32, complete: bool };
pub const State = enum { hello, connecting, relaying, closed };
pub const CloseReason = enum { complete, invalid_hello, no_route, connect_failed, io_error, timeout, stopping };
pub const Direction = struct { buffer: Buffer, eof: bool = false, fin: bool = false };
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
    to_backend: Direction,
    to_client: Direction,
    entered_ms: u64,
    activity_ms: u64,

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

    pub fn expire(self: *Connection, limits: config_mod.Raw, now: u64, counts: *Counters) void {
        if (self.deadline(limits)) |when| if (now >= when) {
            counts.timeouts +%= 1;
            self.close(.timeout);
        };
    }

    /// backend_ready is set only for the registered connect socket's event.
    /// No completion, callback, or borrowed slice can outlive this invocation.
    pub fn drive(self: *Connection, io: anytype, config: *const Config, now: u64, backend_ready: bool, counts: *Counters) void {
        self.expire(config.raw.value, now, counts);
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
        if (!self.pump(io, &self.to_backend, self.client, self.backend, true, now, counts)) return;
        if (!self.pump(io, &self.to_client, self.backend, self.client, false, now, counts)) return;
        if (self.to_backend.fin and self.to_client.fin) self.close(.complete);
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
        var calls: usize = 0;
        while (calls < 64) : (calls += 1) {
            if (self.stage_len == stage.len) break;
            const n = switch (io.recv(self.client, stage[self.stage_len..])) {
                .ok => |n| n,
                .err => |err| {
                    if (err == .AGAIN) return;
                    self.failIo(.client, .read, .{ .errno = err }, counts);
                    return;
                },
            };
            if (n == 0) break;
            self.stage_len += n;
            switch (hello.parse(stage[0..self.stage_len])) {
                .need_more => continue,
                .invalid => break,
                .ok => |maybe_name| {
                    const name = maybe_name;
                    var destination = config.lookup(if (name) |*value| value else null);
                    if (destination == null) {
                        if (name == null) counts.missing_sni +%= 1 else counts.unknown_sni +%= 1;
                        destination = config.fallback;
                    }
                    const endpoint = destination orelse {
                        self.close(.no_route);
                        return;
                    };
                    counts.routed +%= 1;
                    const connecting = io.startConnect(endpoint) catch {
                        counts.connect_failures +%= 1;
                        self.close(.connect_failed);
                        return;
                    };
                    self.backend = connecting.fd;
                    self.entered_ms = now;
                    self.activity_ms = now;
                    self.state = if (connecting.complete) .relaying else .connecting;
                    return;
                },
            }
        }
        // A fairness yield is different from incomplete data at the cap/EOF.
        if (calls == 64 and self.stage_len < stage.len) return;
        counts.invalid_client_hello +%= 1;
        self.close(.invalid_hello);
    }

    fn pump(self: *Connection, io: anytype, direction: *Direction, source: i32, target: i32, forward: bool, now: u64, counts: *Counters) bool {
        var calls: usize = 0;
        var sent: usize = 0;
        var read_blocked = false;
        var write_blocked = false;
        // Drain multiple chunks in one readiness turn, with a fairness quantum.
        // Level-triggered epoll redispatches unfinished ready work.
        while (calls < 128 and sent < 256 * 1024) {
            var progress = false;
            const has_prefix = forward and self.stage != null;
            const queued = if (has_prefix) self.stage.?[self.stage_sent..self.stage_len] else direction.buffer.readable();
            if (queued.len != 0 and !write_blocked) {
                calls += 1;
                const n = switch (io.send(target, queued[0..@min(queued.len, 256 * 1024 - sent)])) {
                    .ok => |n| n,
                    .err => |err| blk: {
                        if (err != .AGAIN) {
                            self.failIo(if (forward) .backend else .client, .write, .{ .errno = err }, counts);
                            return false;
                        }
                        write_blocked = true;
                        break :blk 0;
                    },
                };
                if (n == 0 and !write_blocked) {
                    self.failIo(if (forward) .backend else .client, .write, .zero_write, counts);
                    return false;
                }
                if (n != 0) {
                    if (has_prefix) {
                        self.stage_sent += n;
                        if (self.stage_sent == self.stage_len) self.stage = null;
                    } else direction.buffer.consumed(n);
                    if (forward) counts.bytes_client_to_backend +%= n else counts.bytes_backend_to_client +%= n;
                    self.activity_ms = now;
                    sent += n;
                    progress = true;
                }
            }
            if ((!forward or self.stage == null) and !direction.eof and !read_blocked and direction.buffer.len < direction.buffer.data.len and calls < 128) {
                calls += 1;
                const n = switch (io.recv(source, direction.buffer.writable())) {
                    .ok => |n| n,
                    .err => |err| blk: {
                        if (err != .AGAIN) {
                            self.failIo(if (forward) .client else .backend, .read, .{ .errno = err }, counts);
                            return false;
                        }
                        read_blocked = true;
                        break :blk 0;
                    },
                };
                if (!read_blocked) {
                    if (n == 0) direction.eof = true else {
                        direction.buffer.produced(n);
                        self.activity_ms = now;
                    }
                    progress = true;
                }
            }
            if (direction.eof and direction.buffer.len == 0 and (!forward or self.stage == null) and !direction.fin) {
                switch (io.shutdown(target)) {
                    .ok => {},
                    .err => |err| {
                        if (err != .NOTCONN) {
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
            if (!progress) break;
        }
        return true;
    }

    pub fn interest(self: *const Connection, backend: bool) Interest {
        return switch (self.state) {
            .hello => if (backend) .{} else .{ .read = true },
            .connecting => if (backend) .{ .write = true } else .{},
            .closed => .{},
            .relaying => if (backend) .{
                .read = !self.to_client.eof and self.to_client.buffer.len < self.to_client.buffer.data.len,
                .write = self.stage != null or self.to_backend.buffer.len != 0,
            } else .{
                .read = self.stage == null and !self.to_backend.eof and self.to_backend.buffer.len < self.to_backend.buffer.data.len,
                .write = self.to_client.buffer.len != 0,
            },
        };
    }
};
