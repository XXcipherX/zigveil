const std = @import("std");
const linux = std.os.linux;
const net = @import("linux_io.zig");
const Config = @import("config.zig").Config;
const Connection = @import("connection.zig").Connection;
const Pool = @import("pool.zig").Pool;
const Timers = @import("timers.zig").Timers;
const Counters = @import("counters.zig").Counters;
const logging = @import("log.zig");
const hello_bytes = @import("client_hello.zig").max_wire_bytes;
const metrics = @import("metrics.zig");
const relay_pipe = @import("relay_pipe.zig");
const Slot = struct {
    conn: Connection = undefined,
    staging: ?u32 = null,
    registered: [2]bool = .{ false, false },
    masks: [2]u32 = .{ 0, 0 },
    timer_state: ?@import("connection.zig").State = null,
    timer_prefix: bool = false,
    diagnostic: if (metrics.enabled) struct { batch: u64 = 0, role: bool = false, both: bool = false } else struct {} = .{},
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    config: *const Config,
    log: *logging.Logger,
    slots: []Slot,
    pool: Pool,
    stages: Pool,
    timers: Timers,
    relay_slab: []u8,
    stage_slab: []u8,
    epoll: i32,
    listener: i32,
    signals: i32,
    previous_mask: linux.sigset_t,
    previous_sigpipe: if (relay_pipe.enabled) linux.Sigaction else void,
    counts: Counters = .{},
    io: net.Io = .{},
    listener_registered: bool = true,
    accept_resume_ms: u64 = 0,
    stop_deadline_ms: ?u64 = null,
    diagnostic_batch: if (metrics.enabled) u64 else void = if (metrics.enabled) 0 else {},

    pub fn init(allocator: std.mem.Allocator, config: *const Config, log: *logging.Logger) !Server {
        const raw = config.raw.value;
        try net.checkFdLimit(raw.max_connections);
        const slots = try allocator.alloc(Slot, raw.max_connections);
        errdefer allocator.free(slots);
        @memset(slots, .{});
        var pool = try Pool.init(allocator, raw.max_connections);
        errdefer pool.deinit(allocator);
        var stages = try Pool.init(allocator, raw.max_handshakes);
        errdefer stages.deinit(allocator);
        var timers = try Timers.init(allocator, raw.max_connections);
        errdefer timers.deinit(allocator);
        const relay_slab = try allocator.alloc(u8, @as(usize, raw.max_connections) * 2 * raw.relay_buffer_bytes);
        errdefer allocator.free(relay_slab);
        const stage_slab = try allocator.alloc(u8, @as(usize, raw.max_handshakes) * hello_bytes);
        errdefer allocator.free(stage_slab);
        const epoll_rc = linux.epoll_create1(linux.EPOLL.CLOEXEC);
        if (linux.errno(epoll_rc) != .SUCCESS) return error.EpollCreateFailed;
        const epoll: i32 = @intCast(epoll_rc);
        errdefer net.close(epoll);
        var mask = linux.sigemptyset();
        linux.sigaddset(&mask, .INT);
        linux.sigaddset(&mask, .TERM);
        linux.sigaddset(&mask, .USR1);
        linux.sigaddset(&mask, .USR2);
        var previous_mask: linux.sigset_t = undefined;
        if (linux.errno(linux.sigprocmask(linux.SIG.BLOCK, &mask, &previous_mask)) != .SUCCESS) return error.SignalMaskFailed;
        errdefer _ = linux.sigprocmask(linux.SIG.SETMASK, &previous_mask, null);
        const signal_rc = linux.signalfd(-1, &mask, linux.SFD.NONBLOCK | linux.SFD.CLOEXEC);
        if (linux.errno(signal_rc) != .SUCCESS) return error.SignalFdFailed;
        const signals: i32 = @intCast(signal_rc);
        errdefer net.close(signals);
        const listener = try net.listen(config.listen, raw.reuse_port);
        errdefer net.close(listener);
        var previous_sigpipe: if (relay_pipe.enabled) linux.Sigaction else void = undefined;
        if (relay_pipe.enabled) {
            // splice lacks MSG_NOSIGNAL. EPIPE must remain an ordinary typed
            // connection error, so ignore SIGPIPE for the serving lifetime.
            const ignore: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.IGN }, .mask = linux.sigemptyset(), .flags = 0 };
            if (linux.errno(linux.sigaction(.PIPE, &ignore, &previous_sigpipe)) != .SUCCESS) return error.SigpipeIgnoreFailed;
        }
        errdefer if (relay_pipe.enabled) {
            _ = linux.sigaction(.PIPE, &previous_sigpipe, null);
        };
        var io: net.Io = .{};
        try control(epoll, linux.EPOLL.CTL_ADD, listener, linux.EPOLL.IN, 0, &io.metrics);
        try control(epoll, linux.EPOLL.CTL_ADD, signals, linux.EPOLL.IN, 1, &io.metrics);
        return .{
            .allocator = allocator,
            .config = config,
            .log = log,
            .slots = slots,
            .pool = pool,
            .stages = stages,
            .timers = timers,
            .relay_slab = relay_slab,
            .stage_slab = stage_slab,
            .epoll = epoll,
            .listener = listener,
            .signals = signals,
            .previous_mask = previous_mask,
            .previous_sigpipe = previous_sigpipe,
            .io = io,
        };
    }

    pub fn deinit(self: *Server) void {
        for (self.pool.entries, 0..) |entry, index| if (entry.used) self.drop(@intCast(index));
        self.io.deinit();
        net.close(self.listener);
        net.close(self.signals);
        net.close(self.epoll);
        if (relay_pipe.enabled) _ = linux.sigaction(.PIPE, &self.previous_sigpipe, null);
        _ = linux.sigprocmask(linux.SIG.SETMASK, &self.previous_mask, null);
        self.pool.deinit(self.allocator);
        self.stages.deinit(self.allocator);
        self.timers.deinit(self.allocator);
        self.allocator.free(self.slots);
        self.allocator.free(self.relay_slab);
        self.allocator.free(self.stage_slab);
    }

    pub fn run(self: *Server) !void {
        self.log.message(.info, "started", "listening on {s}; capacity={d} handshakes={d} buffers={f}", .{
            self.config.raw.value.listen, self.slots.len, self.stages.entries.len, logging.Bytes{ .value = Config.bufferBytes(self.config.raw.value) },
        });
        var events: [256]linux.epoll_event = undefined;
        var now = try net.nowMs();
        self.log.begin(now, &self.counts);
        var stats = now + self.config.raw.value.stats_interval_ms;
        while (true) {
            if (self.stop_deadline_ms) |deadline| {
                if (self.counts.active == 0 or now >= deadline) break;
            }
            var wake = now +| 250;
            if (self.timers.first()) |timer| wake = @min(wake, timer.when);
            if (self.stop_deadline_ms) |deadline| wake = @min(wake, deadline);
            if (!self.listener_registered and self.stop_deadline_ms == null) wake = @min(wake, self.accept_resume_ms);
            if (self.config.raw.value.stats_interval_ms != 0) wake = @min(wake, stats);
            const timeout: i32 = @intCast(wake -| now);
            self.io.metrics.add("epoll_wait", 1);
            const rc = linux.epoll_wait(self.epoll, &events, events.len, timeout);
            if (linux.errno(rc) == .INTR) continue;
            if (linux.errno(rc) != .SUCCESS) return error.EpollWaitFailed;
            self.io.metrics.add("epoll_events", rc);
            self.io.metrics.maximum("epoll_max_batch", rc);
            if (rc == events.len) self.io.metrics.add("epoll_full_batches", 1);
            if (metrics.enabled) self.diagnostic_batch +%= 1;
            now = try net.nowMs();
            for (events[0..rc]) |event| {
                const token = event.data.u64;
                if (token == 0) {
                    self.io.metrics.add("listener_events", 1);
                    if (self.listener_registered and self.stop_deadline_ms == null) try self.admit(now);
                    continue;
                }
                if (token == 1) {
                    self.io.metrics.add("signal_events", 1);
                    try self.signal(now);
                    continue;
                }
                const index = self.pool.resolve(token) orelse {
                    self.io.metrics.add("stale_events", 1);
                    continue;
                };
                self.io.metrics.add("connection_events", 1);
                const conn = &self.slots[index].conn;
                const backend = token & 1 != 0;
                if (metrics.enabled) {
                    const diagnostic = &self.slots[index].diagnostic;
                    if (diagnostic.batch == self.diagnostic_batch) {
                        self.io.metrics.add("coalescible_events", 1);
                        if (diagnostic.role != backend and !diagnostic.both) {
                            diagnostic.both = true;
                            self.io.metrics.add("batch_both", 1);
                            if (backend) self.io.metrics.add("batch_client_only", std.math.maxInt(u64)) else self.io.metrics.add("batch_backend_only", std.math.maxInt(u64));
                        }
                    } else {
                        diagnostic.* = .{ .batch = self.diagnostic_batch, .role = backend };
                        if (backend) self.io.metrics.add("batch_backend_only", 1) else self.io.metrics.add("batch_client_only", 1);
                    }
                }
                if (event.events & linux.EPOLL.ERR != 0 and conn.state != .connecting) {
                    conn.checkSocketError(&self.io, backend, &self.counts);
                }
                conn.drive(&self.io, self.config, now, backend, &self.counts);
                try self.reconcile(index);
            }
            // Only due heap entries are visited. Activity can postpone an idle
            // deadline without touching the heap on every successful recv/send.
            now = try net.nowMs();
            for (0..256) |_| {
                const timer = self.timers.first() orelse break;
                if (timer.when > now) break;
                const conn = &self.slots[timer.slot].conn;
                conn.expire(self.config.raw.value, now, &self.counts);
                if (conn.state == .closed) self.drop(timer.slot) else self.timers.set(timer.slot, conn.deadline(self.config.raw.value));
            }
            if (!self.listener_registered and self.stop_deadline_ms == null and now >= self.accept_resume_ms) {
                try control(self.epoll, linux.EPOLL.CTL_ADD, self.listener, linux.EPOLL.IN, 0, &self.io.metrics);
                self.listener_registered = true;
            }
            if (self.config.raw.value.stats_interval_ms != 0 and now >= stats) {
                self.log.periodic(&self.counts);
                stats = now + self.config.raw.value.stats_interval_ms;
            }
            self.log.tick(now, &self.counts);
        }
        for (self.pool.entries, 0..) |entry, index| if (entry.used) self.drop(@intCast(index));
        self.log.stopped(&self.counts);
    }

    fn admit(self: *Server, now: u64) !void {
        for (0..64) |_| {
            self.io.metrics.add("accept4", 1);
            const fd = net.accept(self.listener) catch |err| {
                if (err == error.WouldBlock) return;
                if (err == error.Interrupted) continue;
                self.counts.accept_errors +%= 1;
                if (err == error.TransientConnectionError) continue;
                if (err != error.ResourcePressure) return err;
                try control(self.epoll, linux.EPOLL.CTL_DEL, self.listener, 0, 0, &self.io.metrics);
                self.listener_registered = false;
                self.accept_resume_ms = now + 250;
                return;
            };
            self.counts.accepted +%= 1;
            if (self.pool.free == null or self.stages.free == null) {
                self.counts.rejected +%= 1;
                self.io.metrics.add("close", 1);
                net.close(fd);
                continue;
            }
            net.option(fd, linux.IPPROTO.TCP, linux.TCP.NODELAY, 1) catch {
                self.counts.rejected +%= 1;
                self.io.metrics.add("close", 1);
                net.close(fd);
                continue;
            };
            const index = self.pool.acquire().?;
            const staging = self.stages.acquire().?;
            const bytes = self.config.raw.value.relay_buffer_bytes;
            const start = @as(usize, index) * 2 * bytes;
            self.slots[index] = .{
                .conn = Connection.init(fd, self.stage_slab[@as(usize, staging) * hello_bytes ..][0..hello_bytes], self.relay_slab[start..][0..bytes], self.relay_slab[start + bytes ..][0..bytes], now),
                .staging = staging,
            };
            self.counts.active += 1;
            // Start immediately; already-arrived hello bytes need no extra turn.
            self.slots[index].conn.drive(&self.io, self.config, now, false, &self.counts);
            try self.reconcile(index);
        }
    }

    fn reconcile(self: *Server, index: u32) !void {
        const slot = &self.slots[index];
        if (slot.conn.state == .closed) {
            self.drop(index);
            return;
        }
        if (slot.conn.stage == null) if (slot.staging) |staging| {
            self.stages.release(staging);
            slot.staging = null;
        };
        const prefix = slot.conn.stage != null;
        if (slot.timer_state == null or slot.timer_state.? != slot.conn.state or slot.timer_prefix != prefix) {
            if (slot.timer_state == null or slot.timer_state.? != slot.conn.state)
                self.log.message(.debug, "connection", "connection id={d} phase={s}", .{ self.pool.token(index, false), @tagName(slot.conn.state) });
            self.timers.set(index, slot.conn.deadline(self.config.raw.value));
            slot.timer_state = slot.conn.state;
            slot.timer_prefix = prefix;
        }
        for (0..2) |role| {
            const backend = role == 1;
            const fd = if (backend) slot.conn.backend else slot.conn.client;
            if (fd < 0) continue;
            const interest = slot.conn.interest(backend);
            var mask: u32 = 0;
            if (interest.read) mask |= linux.EPOLL.IN | linux.EPOLL.RDHUP;
            if (interest.write) mask |= linux.EPOLL.OUT;
            if (mask == 0) {
                if (slot.registered[role]) {
                    if (metrics.enabled and !interest.read) self.io.metrics.add("read_paused", 1);
                    try control(self.epoll, linux.EPOLL.CTL_DEL, fd, 0, 0, &self.io.metrics);
                    slot.registered[role] = false;
                }
            } else if (!slot.registered[role] or slot.masks[role] != mask) {
                if (metrics.enabled and interest.write and slot.masks[role] & linux.EPOLL.OUT == 0) self.io.metrics.add("write_interest", 1);
                if (metrics.enabled and !interest.read and slot.masks[role] & linux.EPOLL.IN != 0) self.io.metrics.add("read_paused", 1);
                try control(self.epoll, if (slot.registered[role]) linux.EPOLL.CTL_MOD else linux.EPOLL.CTL_ADD, fd, mask, self.pool.token(index, backend), &self.io.metrics);
                slot.registered[role] = true;
            }
            slot.masks[role] = mask;
        }
    }

    fn drop(self: *Server, index: u32) void {
        const slot = &self.slots[index];
        if (slot.conn.state != .closed) slot.conn.close(.stopping);
        if (self.log.enabled(.debug)) {
            const id = self.pool.token(index, false);
            if (slot.conn.io_failure) |detail| {
                switch (detail.failure) {
                    .errno => |err| self.log.message(.debug, "connection_closed", "connection id={d} closed reason=io_error side={s} operation={s} errno={d}", .{
                        id, @tagName(detail.side), @tagName(detail.operation), @backingInt(err),
                    }),
                    .zero_write => self.log.message(.debug, "connection_closed", "connection id={d} closed reason=zero_write side={s} operation={s}", .{
                        id, @tagName(detail.side), @tagName(detail.operation),
                    }),
                }
            } else self.log.message(.debug, "connection_closed", "connection id={d} closed reason={s}", .{ id, @tagName(slot.conn.reason) });
        }
        self.timers.set(index, null);
        // DEL before close, and generation validation before every batch event.
        for (0..2) |role| if (slot.registered[role]) {
            self.io.metrics.add("epoll_del", 1);
            _ = linux.epoll_ctl(self.epoll, linux.EPOLL.CTL_DEL, if (role == 1) slot.conn.backend else slot.conn.client, null);
        };
        net.close(slot.conn.client);
        net.close(slot.conn.backend);
        slot.conn.assertPipesReturned();
        self.io.metrics.add("close", @as(u64, 1) + @intFromBool(slot.conn.backend >= 0));
        if (slot.staging) |staging| self.stages.release(staging);
        self.pool.release(index);
        self.counts.active -= 1;
        self.counts.closed +%= 1;
    }

    fn signal(self: *Server, now: u64) !void {
        for (0..32) |_| {
            var info: linux.signalfd_siginfo = undefined;
            const bytes = std.mem.asBytes(&info);
            const rc = linux.read(self.signals, bytes.ptr, bytes.len);
            switch (linux.errno(rc)) {
                .AGAIN => return,
                .INTR => continue,
                .SUCCESS => if (rc != bytes.len) return error.SignalReadFailed,
                else => return error.SignalReadFailed,
            }
            if (info.signo == @backingInt(linux.SIG.USR1)) {
                self.log.snapshot(&self.counts);
                if (metrics.enabled) {
                    var storage: [metrics.capacity]u8 = undefined;
                    net.printBytes(self.io.metrics.snapshot(&storage));
                }
            } else if (info.signo == @backingInt(linux.SIG.USR2)) {
                self.log.cycle(now, &self.counts);
            } else if (self.stop_deadline_ms != null) {
                self.log.message(.warn, "stopping", "forcing shutdown; active={d}", .{self.counts.active});
                self.stop_deadline_ms = now;
            } else {
                self.log.message(.info, "stopping", "draining; active={d}; deadline=30s", .{self.counts.active});
                self.stop_deadline_ms = now + 30000;
                if (self.listener_registered) try control(self.epoll, linux.EPOLL.CTL_DEL, self.listener, 0, 0, &self.io.metrics);
                self.listener_registered = false;
                net.close(self.listener);
                self.io.metrics.add("close", 1);
                self.listener = -1;
            }
        }
    }
};

fn control(epoll: i32, operation: u32, fd: i32, mask: u32, token: u64, diagnostic: *metrics.Metrics) !void {
    switch (operation) {
        linux.EPOLL.CTL_ADD => diagnostic.add("epoll_add", 1),
        linux.EPOLL.CTL_MOD => diagnostic.add("epoll_mod", 1),
        linux.EPOLL.CTL_DEL => diagnostic.add("epoll_del", 1),
        else => unreachable,
    }
    var event: linux.epoll_event = .{ .events = mask, .data = .{ .u64 = token } };
    if (linux.errno(linux.epoll_ctl(epoll, operation, fd, if (operation == linux.EPOLL.CTL_DEL) null else &event)) != .SUCCESS) return error.EpollControlFailed;
}
