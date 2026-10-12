//! Cold control messages only. TCP state and byte counters remain worker-local.
const std = @import("std");
const linux = std.os.linux;
const net = @import("linux_io.zig");
const logging = @import("log.zig");
const Counters = @import("counters.zig").Counters;
const metrics = @import("metrics.zig");

pub const start: u32 = 1;
pub const stop: u32 = 2;
pub const snapshot: u32 = 4;
pub const level: u32 = 8;
pub const health_timeout_ms: u64 = 30000;

pub const Snapshot = struct {
    counts: Counters = .{},
    diagnostic: metrics.Metrics = .{},
};

pub const Control = struct {
    fd: i32,
    reply_fd: i32,
    commands: std.atomic.Value(u32) = .init(0),
    requested: std.atomic.Value(u64) = .init(0),
    published: std.atomic.Value(u64) = .init(0),
    desired_level: std.atomic.Value(u8) = .init(0),
    heartbeat: std.atomic.Value(u64) align(64) = .init(0),
    // Only the owner writes; the controller reads after published.acquire.
    // No second request may be sent until the previous snapshot is consumed.
    value: Snapshot = .{},

    pub fn request(self: *Control, flags: u32) !void {
        _ = self.commands.fetchOr(flags, .release);
        try notify(self.fd);
    }

    pub fn take(self: *Control) !u32 {
        try drain(self.fd);
        return self.commands.swap(0, .acquire);
    }

    pub fn publish(self: *Control, counts: Counters, diagnostic: metrics.Metrics) !void {
        self.value = .{ .counts = counts, .diagnostic = diagnostic };
        self.published.store(self.requested.load(.monotonic), .release);
        try notify(self.reply_fd);
    }
};

pub fn createEvent() !i32 {
    const rc = linux.eventfd(0, linux.EFD.NONBLOCK | linux.EFD.CLOEXEC);
    if (linux.errno(rc) != .SUCCESS) return error.WorkerEventFdFailed;
    return @intCast(rc);
}

pub fn notify(fd: i32) !void {
    var value: u64 = 1;
    const bytes = std.mem.asBytes(&value);
    for (0..32) |_| {
        const rc = linux.write(fd, bytes.ptr, bytes.len);
        switch (linux.errno(rc)) {
            .SUCCESS => return if (rc == bytes.len) {} else error.WorkerWakeFailed,
            .AGAIN => return, // A saturated eventfd is already readable.
            .INTR => continue,
            else => return error.WorkerWakeFailed,
        }
    }
    return error.WorkerWakeFailed;
}

pub fn drain(fd: i32) !void {
    for (0..32) |_| {
        var value: u64 = undefined;
        const bytes = std.mem.asBytes(&value);
        const rc = linux.read(fd, bytes.ptr, bytes.len);
        switch (linux.errno(rc)) {
            .SUCCESS => return if (rc == bytes.len) {} else error.WorkerReadFailed,
            .AGAIN => return,
            .INTR => continue,
            else => return error.WorkerReadFailed,
        }
    }
    return error.WorkerReadFailed;
}

pub fn share(total: u32, workers: u8, index: u8) u32 {
    return total / workers + @intFromBool(index < total % workers);
}

pub fn combine(target: *Snapshot, source: Snapshot) void {
    // Reflecting every diagnostic field exceeds Zig's default comptime quota.
    @setEvalBranchQuota(10000);
    inline for (@typeInfo(Counters).@"struct".field_names) |field| {
        if (comptime !std.mem.eql(u8, field, "last_other_io_errno")) @field(target.counts, field) +%= @field(source.counts, field);
    }
    if (metrics.enabled) inline for (@typeInfo(metrics.Counts).@"struct".field_names) |field| {
        if (comptime std.mem.find(u8, field, "max") != null) {
            @field(target.diagnostic.values, field) = @max(@field(target.diagnostic.values, field), @field(source.diagnostic.values, field));
        } else @field(target.diagnostic.values, field) +%= @field(source.diagnostic.values, field);
    };
}

/// A futex mutex protects complete log writes only, never sockets or snapshots.
pub const Writer = struct {
    sink: logging.Sink,
    state: std.atomic.Value(u32) = .init(0),

    pub fn write(context: ?*anyopaque, bytes: []const u8) void {
        const self: *Writer = @ptrCast(@alignCast(context.?));
        if (self.state.cmpxchgStrong(0, 1, .acquire, .monotonic) != null) {
            while (self.state.swap(2, .acquire) != 0) {
                _ = linux.futex_4arg(&self.state, .{ .cmd = .WAIT, .private = true }, 2, null);
            }
        }
        defer if (self.state.swap(0, .release) == 2) {
            _ = linux.futex_3arg(&self.state.raw, .{ .cmd = .WAKE, .private = true }, 1);
        };
        self.sink.write(self.sink.context, bytes);
    }
};

test "partition preserves aggregate limits including unequal remainders" {
    for (2..17) |n| {
        const workers: u8 = @intCast(n);
        var c: u32 = 0;
        var h: u32 = 0;
        for (0..n) |i| {
            const index: u8 = @intCast(i);
            const local_c = share(1031, workers, index);
            const local_h = share(67, workers, index);
            try std.testing.expect(local_h > 0 and local_h <= local_c);
            c += local_c;
            h += local_h;
        }
        try std.testing.expectEqual(@as(u32, 1031), c);
        try std.testing.expectEqual(@as(u32, 67), h);
    }
}

test "eventfd commands coalesce without losing stop or snapshot" {
    const fd = try createEvent();
    defer net.close(fd);
    const reply = try createEvent();
    defer net.close(reply);
    var control: Control = .{ .fd = fd, .reply_fd = reply };
    try control.request(snapshot);
    try control.request(stop);
    try std.testing.expectEqual(snapshot | stop, try control.take());
    try std.testing.expectEqual(@as(u32, 0), try control.take());
}

test "aggregate adds counters and retains diagnostic maxima without summing errno" {
    var a: Snapshot = .{ .counts = .{ .active = 2, .accepted = 7, .bytes_client_to_backend = 123, .last_other_io_errno = 77 } };
    var b: Snapshot = .{ .counts = .{ .active = 3, .accepted = 11, .bytes_client_to_backend = 456, .last_other_io_errno = 88 } };
    a.diagnostic.maximum("recv_max", 8192);
    b.diagnostic.maximum("recv_max", 4096);
    a.diagnostic.add("pipe_live", 1);
    b.diagnostic.add("pipe_live", 1);
    var sum: Snapshot = .{};
    combine(&sum, a);
    combine(&sum, b);
    try std.testing.expectEqual(@as(u64, 5), sum.counts.active);
    try std.testing.expectEqual(@as(u64, 18), sum.counts.accepted);
    try std.testing.expectEqual(@as(u64, 579), sum.counts.bytes_client_to_backend);
    try std.testing.expectEqual(@as(u64, 0), sum.counts.last_other_io_errno);
    if (metrics.enabled) {
        try std.testing.expectEqual(@as(u64, 8192), sum.diagnostic.get("recv_max"));
        try std.testing.expectEqual(@as(u64, 2), sum.diagnostic.get("pipe_live"));
    }
}

test "concurrent log sinks preserve complete lines" {
    const Capture = struct {
        bytes: [2048]u8 = undefined,
        len: usize = 0,
        fn write(ctx: ?*anyopaque, bytes: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            @memcpy(self.bytes[self.len..][0..bytes.len], bytes);
            self.len += bytes.len;
        }
    };
    const Job = struct {
        fn run(writer: *Writer) void {
            for (0..32) |_| Writer.write(writer, "line\n");
        }
    };
    var capture: Capture = .{};
    var writer: Writer = .{ .sink = .{ .context = &capture, .write = Capture.write } };
    var threads: [4]std.Thread = undefined;
    var spawned: usize = 0;
    defer for (threads[0..spawned]) |thread| thread.join();
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, Job.run, .{&writer});
        spawned += 1;
    }
    for (threads[0..spawned]) |thread| thread.join();
    spawned = 0;
    try std.testing.expectEqual(@as(usize, 4 * 32 * 5), capture.len);
    for (0..128) |i| try std.testing.expectEqualStrings("line\n", capture.bytes[i * 5 ..][0..5]);
}
