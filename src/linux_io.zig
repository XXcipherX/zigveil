//! Zig 0.16 Linux syscall boundary; no libc and no async runtime dependency.
const std = @import("std");
const linux = std.os.linux;
const Address = @import("config.zig").Address;
const Connect = @import("connection.zig").Connect;
const Result = @import("io_result.zig").Result;
const relay_pipe = @import("relay_pipe.zig");

pub const Io = struct {
    metrics: @import("metrics.zig").Metrics = .{},
    shared_pipes: if (relay_pipe.enabled) ?relay_pipe.Pair else void = if (relay_pipe.enabled) null else {},
    shared_attempted: if (relay_pipe.enabled) bool else void = if (relay_pipe.enabled) false else {},

    pub fn recv(self: *Io, fd: i32, bytes: []u8) Result(usize) {
        while (true) {
            const rc = linux.recvfrom(fd, bytes.ptr, bytes.len, 0, null, null);
            self.metrics.recvResult(rc);
            if (linux.errno(rc) == .INTR) continue;
            return transferResult(rc);
        }
    }

    pub fn send(self: *Io, fd: i32, bytes: []const u8) Result(usize) {
        while (true) {
            const rc = linux.sendto(fd, bytes.ptr, bytes.len, linux.MSG.NOSIGNAL, null, 0);
            self.metrics.sendResult(rc, bytes.len);
            if (linux.errno(rc) == .INTR) continue;
            return transferResult(rc);
        }
    }

    pub fn shutdown(self: *Io, fd: i32) Result(void) {
        while (true) {
            self.metrics.add("shutdown", 1);
            const err = linux.errno(linux.shutdown(fd, 1)); // SHUT_WR
            if (err == .INTR) continue;
            return statusResult(err);
        }
    }

    pub fn startConnect(self: *Io, endpoint: Address) !Connect {
        const addr = SockAddress.init(endpoint);
        const fd = try socket(addr.storage.family);
        errdefer {
            self.metrics.add("close", 1);
            close(fd);
        }
        try option(fd, linux.IPPROTO.TCP, linux.TCP.NODELAY, 1);
        self.metrics.add("connect", 1);
        const rc = linux.connect(fd, &addr.storage, addr.len);
        return switch (linux.errno(rc)) {
            .SUCCESS => .{ .fd = fd, .complete = true },
            .INPROGRESS, .INTR => .{ .fd = fd, .complete = false },
            else => error.BackendConnectFailed,
        };
    }

    pub fn finishConnect(self: *Io, fd: i32) !void {
        switch (socketErrorMeasured(fd, &self.metrics)) {
            .ok => {},
            .err => return error.SocketError,
        }
    }

    pub fn checkSocketError(self: *Io, fd: i32) Result(void) {
        return socketErrorMeasured(fd, &self.metrics);
    }

    pub fn openRelayPipes(self: *Io, capacity: usize) ?relay_pipe.Pair {
        if (!relay_pipe.enabled) return null;
        if (relay_pipe.enabled) {
            if (self.shared_attempted) {
                if (self.shared_pipes != null) self.metrics.add("pipe_reuses", 1);
                return self.shared_pipes;
            }
            self.shared_attempted = true;
        }
        var pipes: relay_pipe.Pair = undefined;
        var opened: usize = 0;
        var complete = false;
        defer if (!complete) {
            for (pipes[0..opened]) |pipe| for (pipe.fds) |fd| {
                self.metrics.add("close", 1);
                close(fd);
            };
            self.metrics.add("pipe_fallbacks", 1);
        };
        for (&pipes) |*pipe| {
            self.metrics.add("pipe2", 1);
            if (linux.errno(linux.pipe2(&pipe.fds, .{ .NONBLOCK = true, .CLOEXEC = true })) != .SUCCESS) return null;
            opened += 1;
            self.metrics.add("fcntl", 1);
            const rc = linux.fcntl(pipe.fds[0], linux.F.SETPIPE_SZ, capacity);
            // Never serve through tiny quota-reduced pipes. Both allocations
            // must meet the bounded configured capacity or use the ring path.
            if (linux.errno(rc) != .SUCCESS or rc != capacity) return null;
            pipe.capacity = capacity;
            pipe.pending = 0;
            pipe.read_paused = false;
        }
        complete = true;
        self.metrics.add("pipe_activations", 1);
        self.metrics.add("pipe_live", 1);
        self.metrics.maximum("pipe_max_capacity", capacity);
        if (relay_pipe.enabled) {
            self.shared_pipes = pipes;
            self.metrics.maximum("shared_pipe_capacity", capacity);
        }
        return pipes;
    }

    fn destroyPipes(self: *Io, pipes: relay_pipe.Pair) void {
        self.metrics.add("pipe_live", std.math.maxInt(u64));
        for (pipes) |pipe| for (pipe.fds) |fd| {
            self.metrics.add("close", 1);
            close(fd);
        };
    }

    pub fn disableSharedPipes(self: *Io) void {
        if (relay_pipe.enabled) if (self.shared_pipes) |pipes| {
            self.destroyPipes(pipes);
            self.shared_pipes = null;
        };
    }

    pub fn deinit(self: *Io) void {
        self.disableSharedPipes();
    }

    pub fn readRelayPipe(self: *Io, fd: i32, bytes: []u8) Result(usize) {
        while (true) {
            self.metrics.add("pipe_read", 1);
            const rc = linux.read(fd, bytes.ptr, bytes.len);
            if (linux.errno(rc) == .INTR) continue;
            return transferResult(rc);
        }
    }

    pub fn spliceRead(self: *Io, source: i32, pipe: i32, bytes: usize) Result(usize) {
        return self.spliceTransfer(source, pipe, bytes, true);
    }

    pub fn spliceWrite(self: *Io, pipe: i32, target: i32, bytes: usize) Result(usize) {
        return self.spliceTransfer(pipe, target, bytes, false);
    }

    fn spliceTransfer(self: *Io, source: i32, target: i32, bytes: usize, comptime read: bool) Result(usize) {
        while (true) {
            // Linux splice ABI; null offsets for sockets/pipes. All four pipe
            // ends and both sockets are nonblocking. SPLICE_F_NONBLOCK = 2.
            const rc = linux.syscall6(.splice, @intCast(source), 0, @intCast(target), 0, bytes, 2);
            self.metrics.spliceResult(rc, bytes, read);
            if (linux.errno(rc) == .INTR) continue;
            return transferResult(rc);
        }
    }
};

fn transferResult(rc: usize) Result(usize) {
    const err = linux.errno(rc);
    return if (err == .SUCCESS) .{ .ok = rc } else .{ .err = err };
}

fn statusResult(err: linux.E) Result(void) {
    return if (err == .SUCCESS) .{ .ok = {} } else .{ .err = err };
}

const SockAddress = struct {
    storage: linux.sockaddr.storage,
    len: linux.socklen_t,

    fn init(endpoint: Address) SockAddress {
        var result: SockAddress = .{ .storage = std.mem.zeroes(linux.sockaddr.storage), .len = 0 };
        switch (endpoint) {
            .ip4 => |a| {
                const addr: linux.sockaddr.in = .{
                    .port = std.mem.nativeToBig(u16, a.port),
                    .addr = @bitCast(a.bytes),
                };
                result.len = @sizeOf(@TypeOf(addr));
                @memcpy(std.mem.asBytes(&result.storage)[0..result.len], std.mem.asBytes(&addr));
            },
            .ip6 => |a| {
                const addr: linux.sockaddr.in6 = .{
                    .port = std.mem.nativeToBig(u16, a.port),
                    .flowinfo = 0,
                    .addr = a.bytes,
                    .scope_id = 0,
                };
                result.len = @sizeOf(@TypeOf(addr));
                @memcpy(std.mem.asBytes(&result.storage)[0..result.len], std.mem.asBytes(&addr));
            },
        }
        return result;
    }
};

fn socket(family: u16) !i32 {
    const rc = linux.socket(family, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, linux.IPPROTO.TCP);
    if (linux.errno(rc) != .SUCCESS) return error.SocketCreateFailed;
    return @intCast(rc);
}

pub fn option(fd: i32, level: i32, name: u32, value: i32) !void {
    const bytes = std.mem.asBytes(&value);
    if (linux.errno(linux.setsockopt(fd, level, name, bytes.ptr, @intCast(bytes.len))) != .SUCCESS) return error.SocketOptionFailed;
}

pub fn socketError(fd: i32) Result(void) {
    return socketErrorMeasured(fd, null);
}

fn socketErrorMeasured(fd: i32, metrics: ?*@import("metrics.zig").Metrics) Result(void) {
    while (true) {
        if (metrics) |m| m.add("getsockopt", 1);
        var value: i32 = 0;
        var len: linux.socklen_t = @sizeOf(i32);
        const err = linux.errno(linux.getsockopt(fd, linux.SOL.SOCKET, linux.SO.ERROR, @ptrCast(&value), &len));
        if (err == .INTR) continue;
        if (err != .SUCCESS) return .{ .err = err };
        // SO_ERROR is a positive errno (or zero), not a syscall return value.
        return statusResult(@enumFromInt(@as(u16, @intCast(value))));
    }
}

pub fn listen(endpoint: Address, reuse_port: bool) !i32 {
    const addr = SockAddress.init(endpoint);
    const fd = try socket(addr.storage.family);
    errdefer close(fd);
    try option(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, 1);
    if (reuse_port) try option(fd, linux.SOL.SOCKET, linux.SO.REUSEPORT, 1);
    if (addr.storage.family == linux.AF.INET6) try option(fd, linux.IPPROTO.IPV6, linux.IPV6.V6ONLY, 1);
    if (linux.errno(linux.bind(fd, @ptrCast(&addr.storage), addr.len)) != .SUCCESS) return error.ListenerBindFailed;
    if (linux.errno(linux.listen(fd, 1024)) != .SUCCESS) return error.ListenerListenFailed;
    return fd;
}

pub const AcceptError = error{ WouldBlock, Interrupted, TransientConnectionError, ResourcePressure, FatalListenerError };

pub fn accept(fd: i32) AcceptError!i32 {
    // One attempt: EINTR and connection errors consume the server's accept budget.
    return acceptResult(linux.accept4(fd, null, null, linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC));
}

fn acceptResult(rc: usize) AcceptError!i32 {
    return switch (linux.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .INTR => error.Interrupted,
        .AGAIN => error.WouldBlock, // Linux EWOULDBLOCK is the same value.
        // accept(2)'s pending TCP/IP errors, plus aborted/reset/timed-out peers.
        // The privately owned listener is always SOCK_STREAM/IPPROTO_TCP, so
        // EOPNOTSUPP here follows the documented pending-network-error rule.
        .CONNABORTED, .CONNRESET, .TIMEDOUT, .NETDOWN, .PROTO, .NOPROTOOPT, .HOSTDOWN, .NONET, .HOSTUNREACH, .OPNOTSUPP, .NETUNREACH => error.TransientConnectionError,
        .MFILE, .NFILE, .NOBUFS, .NOMEM, .NOSR => error.ResourcePressure,
        // Invalid listener/arguments and policy failures cannot be repaired by
        // repeatedly accepting; unknown failures stop the server as well.
        else => error.FatalListenerError,
    };
}

pub fn close(fd: i32) void {
    // Linux releases the fd even on EINTR; retrying could close a reused fd.
    if (fd >= 0) _ = linux.close(fd);
}

pub fn nowMs() !u64 {
    var time: linux.timespec = undefined;
    if (linux.errno(linux.clock_gettime(.MONOTONIC, &time)) != .SUCCESS) return error.ClockFailed;
    return @as(u64, @intCast(time.sec)) * 1000 + @as(u64, @intCast(time.nsec)) / 1_000_000;
}

pub fn checkFdLimit(max_connections: u32) !void {
    const limit = try std.posix.getrlimit(.NOFILE);
    if (relay_pipe.enabled) {
        if (limit.cur < @as(u64, max_connections) * 2 + 12) return error.RaiseRLIMIT_NOFILEToAtLeastTwiceMaxConnectionsPlus12;
    } else if (limit.cur < @as(u64, max_connections) * 2 + 8) return error.RaiseRLIMIT_NOFILEToAtLeastTwiceMaxConnectionsPlus8;
}

pub fn print(comptime format: []const u8, args: anytype) void {
    var storage: [4096]u8 = undefined;
    const bytes = std.fmt.bufPrint(&storage, format, args) catch return;
    printBytes(bytes);
}

pub fn printBytes(bytes: []const u8) void {
    var offset: usize = 0;
    while (offset != bytes.len) {
        const rc = linux.write(2, bytes[offset..].ptr, bytes.len - offset);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return;
                offset += rc;
            },
            .INTR => continue,
            else => return,
        }
    }
}

test "IPv4 and IPv6 sockaddr preserve network byte order" {
    const v4 = SockAddress.init(try Address.parseLiteral("203.0.113.10:443"));
    const a4: *const linux.sockaddr.in = @ptrCast(&v4.storage);
    try std.testing.expectEqual(@as(u16, 443), std.mem.bigToNative(u16, a4.port));
    try std.testing.expectEqualSlices(u8, &.{ 203, 0, 113, 10 }, std.mem.asBytes(&a4.addr));
    const v6 = SockAddress.init(try Address.parseLiteral("[::1]:8443"));
    const a6: *const linux.sockaddr.in6 = @ptrCast(&v6.storage);
    try std.testing.expectEqual(@as(u16, 8443), std.mem.bigToNative(u16, a6.port));
    try std.testing.expectEqual(@as(u8, 1), a6.addr[15]);
}

test "production accept result distinguishes retry, network, pressure and fatal failures" {
    try std.testing.expectEqual(@as(i32, 42), try acceptResult(42));
    const cases = [_]struct { errno: linux.E, failure: AcceptError }{
        .{ .errno = .AGAIN, .failure = error.WouldBlock },
        .{ .errno = .INTR, .failure = error.Interrupted },
        .{ .errno = .CONNABORTED, .failure = error.TransientConnectionError },
        .{ .errno = .CONNRESET, .failure = error.TransientConnectionError },
        .{ .errno = .TIMEDOUT, .failure = error.TransientConnectionError },
        .{ .errno = .NETDOWN, .failure = error.TransientConnectionError },
        .{ .errno = .PROTO, .failure = error.TransientConnectionError },
        .{ .errno = .NOPROTOOPT, .failure = error.TransientConnectionError },
        .{ .errno = .HOSTDOWN, .failure = error.TransientConnectionError },
        .{ .errno = .NONET, .failure = error.TransientConnectionError },
        .{ .errno = .HOSTUNREACH, .failure = error.TransientConnectionError },
        .{ .errno = .OPNOTSUPP, .failure = error.TransientConnectionError },
        .{ .errno = .NETUNREACH, .failure = error.TransientConnectionError },
        .{ .errno = .MFILE, .failure = error.ResourcePressure },
        .{ .errno = .NFILE, .failure = error.ResourcePressure },
        .{ .errno = .NOBUFS, .failure = error.ResourcePressure },
        .{ .errno = .NOMEM, .failure = error.ResourcePressure },
        .{ .errno = .NOSR, .failure = error.ResourcePressure },
        .{ .errno = .BADF, .failure = error.FatalListenerError },
        .{ .errno = .NOTSOCK, .failure = error.FatalListenerError },
        .{ .errno = .INVAL, .failure = error.FatalListenerError },
        .{ .errno = .FAULT, .failure = error.FatalListenerError },
        .{ .errno = .PERM, .failure = error.FatalListenerError },
        .{ .errno = .ACCES, .failure = error.FatalListenerError },
        .{ .errno = .NOSYS, .failure = error.FatalListenerError },
        .{ .errno = .PROTONOSUPPORT, .failure = error.FatalListenerError },
        .{ .errno = .SOCKTNOSUPPORT, .failure = error.FatalListenerError },
        .{ .errno = .IO, .failure = error.FatalListenerError },
    };
    for (cases) |case| {
        const rc: usize = @bitCast(-@as(isize, @intFromEnum(case.errno)));
        try std.testing.expectError(case.failure, acceptResult(rc));
    }
}

test "Linux shutdown boundary reports ENOTCONN and keeps invalid descriptors fatal" {
    var io: Io = .{};
    for ([_]u16{ linux.AF.INET, linux.AF.INET6 }) |family| {
        const fd = try socket(family);
        defer close(fd);
        try std.testing.expectEqual(linux.E.NOTCONN, io.shutdown(fd).err);
        try std.testing.expectEqual(.ok, std.meta.activeTag(io.checkSocketError(fd)));
    }
    try std.testing.expectEqual(linux.E.BADF, io.shutdown(-1).err);
    try std.testing.expectEqual(linux.E.BADF, io.checkSocketError(-1).err);
}

test "transfer decoder preserves exact known, retry and unknown Linux errno" {
    try std.testing.expectEqual(@as(usize, 123), transferResult(123).ok);
    for ([_]linux.E{ .AGAIN, .INTR, .CONNRESET, .PIPE, .NOTCONN, .CONNABORTED, .TIMEDOUT, .NETRESET, .NETDOWN, .NETUNREACH, .HOSTUNREACH, .BADF, @enumFromInt(4090) }) |err| {
        const rc: usize = @bitCast(-@as(isize, @intFromEnum(err)));
        try std.testing.expectEqual(err, transferResult(rc).err);
        try std.testing.expectEqual(err, statusResult(err).err);
    }
}

test "Linux send after local SHUT_WR returns typed EPIPE without SIGPIPE" {
    var fds: [2]i32 = undefined;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0, &fds)));
    defer close(fds[0]);
    defer close(fds[1]);
    var io: Io = .{};
    try std.testing.expectEqual(.ok, std.meta.activeTag(io.shutdown(fds[0])));
    try std.testing.expectEqual(linux.E.PIPE, io.send(fds[0], "queued byte").err);
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(linux.E.AGAIN, io.recv(fds[0], &byte).err);
    try std.testing.expectEqual(linux.E.BADF, io.recv(-1, &byte).err);
}
