//! Optional single-owner diagnostics. Disabled builds contain no counter storage.
const std = @import("std");
const linux = std.os.linux;
pub const enabled = @import("build_options").dataplane_metrics;
pub const capacity = 8192;

pub const Counts = struct {
    recv_attempts: u64 = 0,
    recv_success: u64 = 0,
    recv_eof: u64 = 0,
    recv_again: u64 = 0,
    recv_intr: u64 = 0,
    recv_fatal: u64 = 0,
    recv_bytes: u64 = 0,
    recv_max: u64 = 0,
    send_attempts: u64 = 0,
    send_success: u64 = 0,
    send_again: u64 = 0,
    send_intr: u64 = 0,
    send_fatal: u64 = 0,
    send_bytes: u64 = 0,
    send_max: u64 = 0,
    splice_read_attempts: u64 = 0,
    splice_read_success: u64 = 0,
    splice_read_eof: u64 = 0,
    splice_read_again: u64 = 0,
    splice_read_intr: u64 = 0,
    splice_read_fatal: u64 = 0,
    splice_read_bytes: u64 = 0,
    splice_read_max: u64 = 0,
    splice_write_attempts: u64 = 0,
    splice_write_success: u64 = 0,
    splice_write_again: u64 = 0,
    splice_write_intr: u64 = 0,
    splice_write_fatal: u64 = 0,
    splice_write_bytes: u64 = 0,
    splice_write_max: u64 = 0,
    pipe_activations: u64 = 0,
    pipe_deactivations: u64 = 0,
    pipe_reuses: u64 = 0,
    pipe_read: u64 = 0,
    pipe_spills: u64 = 0,
    pipe_spill_bytes: u64 = 0,
    shared_pipe_capacity: u64 = 0,
    pipe_fallbacks: u64 = 0,
    pipe_max_capacity: u64 = 0,
    pipe_live: u64 = 0,
    pipe2: u64 = 0,
    fcntl: u64 = 0,
    partial_sends: u64 = 0,
    zero_writes: u64 = 0,
    epoll_wait: u64 = 0,
    epoll_events: u64 = 0,
    epoll_max_batch: u64 = 0,
    epoll_full_batches: u64 = 0,
    epoll_add: u64 = 0,
    epoll_mod: u64 = 0,
    epoll_del: u64 = 0,
    connection_events: u64 = 0,
    listener_events: u64 = 0,
    signal_events: u64 = 0,
    stale_events: u64 = 0,
    drive_calls: u64 = 0,
    drive_useful: u64 = 0,
    drive_no_progress: u64 = 0,
    pump_forward: u64 = 0,
    pump_reverse: u64 = 0,
    pump_read_again: u64 = 0,
    pump_write_again: u64 = 0,
    pump_buffer_full: u64 = 0,
    pump_eof: u64 = 0,
    pump_call_budget: u64 = 0,
    pump_byte_budget: u64 = 0,
    pump_no_work: u64 = 0,
    pump_fatal: u64 = 0,
    ring_full: u64 = 0,
    ring_wrap: u64 = 0,
    ring_drained: u64 = 0,
    prefix_completed: u64 = 0,
    read_paused: u64 = 0,
    write_interest: u64 = 0,
    accept4: u64 = 0,
    connect: u64 = 0,
    getsockopt: u64 = 0,
    getpeername: u64 = 0,
    getsockname: u64 = 0,
    shutdown: u64 = 0,
    close: u64 = 0,
};

pub const Metrics = struct {
    values: if (enabled) Counts else void = if (enabled) .{} else {},

    pub inline fn add(self: *Metrics, comptime field: []const u8, n: u64) void {
        if (enabled) @field(self.values, field) +%= n;
    }

    pub inline fn maximum(self: *Metrics, comptime field: []const u8, n: u64) void {
        if (enabled) @field(self.values, field) = @max(@field(self.values, field), n);
    }

    pub inline fn get(self: *const Metrics, comptime field: []const u8) u64 {
        return if (enabled) @field(self.values, field) else 0;
    }

    pub inline fn progress(self: *const Metrics) u64 {
        return self.get("recv_bytes") +% self.get("send_bytes") +% self.get("recv_eof") +%
            self.get("splice_read_bytes") +% self.get("splice_write_bytes") +% self.get("splice_read_eof") +% self.get("shutdown");
    }

    pub inline fn recvResult(self: *Metrics, rc: usize) void {
        if (!enabled) return;
        self.add("recv_attempts", 1);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) self.add("recv_eof", 1) else self.add("recv_success", 1);
                self.add("recv_bytes", rc);
                self.maximum("recv_max", rc);
            },
            .AGAIN => self.add("recv_again", 1),
            .INTR => self.add("recv_intr", 1),
            else => self.add("recv_fatal", 1),
        }
    }

    pub inline fn sendResult(self: *Metrics, rc: usize, requested: usize) void {
        if (!enabled) return;
        self.add("send_attempts", 1);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) self.add("zero_writes", 1) else self.add("send_success", 1);
                self.add("send_bytes", rc);
                self.maximum("send_max", rc);
                if (rc != 0 and rc < requested) self.add("partial_sends", 1);
            },
            .AGAIN => self.add("send_again", 1),
            .INTR => self.add("send_intr", 1),
            else => self.add("send_fatal", 1),
        }
    }

    pub inline fn spliceResult(self: *Metrics, rc: usize, requested: usize, comptime read: bool) void {
        if (!enabled) return;
        const prefix = if (read) "splice_read_" else "splice_write_";
        self.add(prefix ++ "attempts", 1);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) {
                    if (read) self.add("splice_read_eof", 1) else self.add("zero_writes", 1);
                } else self.add(prefix ++ "success", 1);
                self.add(prefix ++ "bytes", rc);
                self.maximum(prefix ++ "max", rc);
                if (!read and rc != 0 and rc < requested) self.add("partial_sends", 1);
            },
            .AGAIN => self.add(prefix ++ "again", 1),
            .INTR => self.add(prefix ++ "intr", 1),
            else => self.add(prefix ++ "fatal", 1),
        }
    }

    pub fn snapshot(self: *const Metrics, bytes: *[capacity]u8) []const u8 {
        const prefix = "{\"event\":\"dataplane\"";
        @memcpy(bytes[0..prefix.len], prefix);
        var length: usize = prefix.len;
        inline for (@typeInfo(Counts).@"struct".field_names) |field_name| {
            const part = std.mem.print(bytes[length..], ",\"" ++ field_name ++ "\":{d}", .{self.get(field_name)}) catch unreachable;
            length += part.len;
        }
        @memcpy(bytes[length..][0..2], "}\n");
        return bytes[0 .. length + 2];
    }
};

comptime {
    var length: usize = 24;
    for (@typeInfo(Counts).@"struct".field_names) |field_name| length += field_name.len + 24;
    if (length > capacity) @compileError("Dataplane snapshot exceeds its fixed buffer");
}

test "disabled diagnostics have zero storage; enabled results preserve retries and maxima" {
    if (!enabled) {
        try std.testing.expectEqual(@as(usize, 0), @sizeOf(Metrics));
        return;
    }
    var metrics: Metrics = .{};
    metrics.recvResult(17);
    metrics.recvResult(0);
    metrics.recvResult(@bitCast(-@as(isize, @backingInt(linux.E.AGAIN))));
    metrics.sendResult(5, 10);
    metrics.sendResult(@bitCast(-@as(isize, @backingInt(linux.E.INTR))), 10);
    try std.testing.expectEqual(@as(u64, 3), metrics.get("recv_attempts"));
    try std.testing.expectEqual(@as(u64, 17), metrics.get("recv_bytes"));
    try std.testing.expectEqual(@as(u64, 1), metrics.get("recv_eof"));
    try std.testing.expectEqual(@as(u64, 1), metrics.get("recv_again"));
    try std.testing.expectEqual(@as(u64, 1), metrics.get("send_intr"));
    try std.testing.expectEqual(@as(u64, 1), metrics.get("partial_sends"));
    var storage: [capacity]u8 = undefined;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, metrics.snapshot(&storage), .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("dataplane", parsed.value.object.get("event").?.string);
}
