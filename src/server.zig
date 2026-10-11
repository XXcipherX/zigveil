const std = @import("std");
const linux = std.os.linux;
const net = @import("linux_io.zig");
const Config = @import("config.zig").Config;
const Connection = @import("connection.zig").Connection;
const Pool = @import("pool.zig").Pool;
const Timers = @import("timers.zig").Timers;
const Counters = @import("counters.zig").Counters;
const logging = @import("log.zig");
const metrics = @import("metrics.zig");
const relay_pipe = @import("relay_pipe.zig");
const Slot = struct {
    conn: Connection = undefined,
    staging: ?u32 = null,
    registered: [2]bool = .{ false, false },
    masks: [2]u32 = .{ 0, 0 },
    timer_state: ?@import("connection.zig").State = null,
    timer_prefix: bool = false,
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
    now_ms: u64 = 0,

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
        const stage_slab = try allocator.alloc(u8, @as(usize, raw.max_handshakes) * Config.stageBytes(raw));
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
        self.now_ms = now;
        self.log.begin(now, &self.counts);
        var stats = now + self.config.raw.value.stats_interval_ms;
        serving: while (true) {
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
            now = try net.nowMs();
            self.now_ms = now;
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
                    if (self.stop_deadline_ms != null) break :serving;
                    continue;
                }
                const index = self.pool.resolve(token) orelse {
                    self.io.metrics.add("stale_events", 1);
                    continue;
                };
                self.io.metrics.add("connection_events", 1);
                const conn = &self.slots[index].conn;
                const backend = token & 1 != 0;
                if (event.events & linux.EPOLL.ERR != 0 and conn.state != .connecting) {
                    conn.checkSocketError(&self.io, backend, &self.counts);
                }
                conn.drive(&self.io, self.config, now, backend, &self.counts);
                try self.reconcile(index);
            }
            // Only due heap entries are visited. Activity can postpone an idle
            // deadline without touching the heap on every successful recv/send.
            now = try net.nowMs();
            self.now_ms = now;
            for (0..256) |_| {
                const timer = self.timers.first() orelse break;
                if (timer.when > now) break;
                const conn = &self.slots[timer.slot].conn;
                const old_state = conn.state;
                conn.expire(&self.io, self.config, now, &self.counts);
                if (conn.state == .closed) {
                    self.drop(timer.slot);
                } else if (conn.state != old_state) {
                    // A hello deadline can select fallback and create a backend.
                    conn.drive(&self.io, self.config, now, false, &self.counts);
                    try self.reconcile(timer.slot);
                } else self.timers.set(timer.slot, conn.deadline(self.config.raw.value));
            }
            if (!self.listener_registered and self.stop_deadline_ms == null and now >= self.accept_resume_ms) {
                try control(self.epoll, linux.EPOLL.CTL_ADD, self.listener, linux.EPOLL.IN, 0, &self.io.metrics);
                self.listener_registered = true;
            }
            if (self.config.raw.value.stats_interval_ms != 0 and now >= stats) {
                self.log.periodic(now, &self.counts);
                stats = now + self.config.raw.value.stats_interval_ms;
            }
            self.log.tick(now);
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
                self.log.warning(.accept_pressure, .{ .phase = .accept });
                try control(self.epoll, linux.EPOLL.CTL_DEL, self.listener, 0, 0, &self.io.metrics);
                self.listener_registered = false;
                self.accept_resume_ms = now + 250;
                return;
            };
            self.counts.accepted +%= 1;
            if (self.pool.free == null or self.stages.free == null) {
                self.counts.rejected +%= 1;
                self.log.warning(if (self.pool.free == null) .connection_capacity else .handshake_capacity, .{ .phase = .accept });
                self.io.metrics.add("close", 1);
                net.close(fd);
                continue;
            }
            net.option(fd, linux.IPPROTO.TCP, linux.TCP.NODELAY, 1) catch {
                self.counts.rejected +%= 1;
                self.log.warning(.socket_setup, .{ .phase = .accept });
                self.io.metrics.add("close", 1);
                net.close(fd);
                continue;
            };
            const index = self.pool.acquire().?;
            const staging = self.stages.acquire().?;
            const stage_bytes = Config.stageBytes(self.config.raw.value);
            const bytes = self.config.raw.value.relay_buffer_bytes;
            const start = @as(usize, index) * 2 * bytes;
            self.slots[index] = .{
                .conn = Connection.init(fd, self.stage_slab[@as(usize, staging) * stage_bytes ..][0..stage_bytes], self.relay_slab[start..][0..bytes], self.relay_slab[start + bytes ..][0..bytes], now),
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
        var context: logging.Context = .{
            .phase = slot.conn.closed_phase,
            .backend = if (slot.conn.route) |route| route.backend else if (slot.conn.fallback) self.config.fallback else null,
            .errno = slot.conn.connect_errno,
        };
        var zero_write = false;
        if (slot.conn.io_failure) |detail| {
            context.side = detail.side;
            context.operation = detail.operation;
            switch (detail.failure) {
                .errno => |err| context.errno = err,
                .zero_write => zero_write = true,
            }
            self.log.ioFailure(context, detail.failure);
        }
        switch (slot.conn.reason) {
            .connect_failed => self.log.warning(.connect_failures, context),
            .timeout => switch (context.phase) {
                .connect => self.log.warning(.connect_timeouts, context),
                .prefix => self.log.warning(.prefix_timeouts, context),
                else => {}, // Hello and ordinary idle expiry are diagnostic data.
            },
            .proxy_metadata_failed => self.log.warning(.metadata_failed, context),
            else => {},
        }
        if (self.log.enabled(.debug)) {
            self.log.closed(.{
                .id = self.pool.token(index, false),
                .lifetime_ms = self.now_ms -| slot.conn.accepted_ms,
                .route = if (slot.conn.route) |route| route.name.slice() else if (slot.conn.fallback) "fallback" else "unselected",
                .reason = @tagName(slot.conn.reason),
                .context = context,
                .zero_write = zero_write,
                .hello_timeout = slot.conn.hello_timeout,
            });
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
            } else if (self.stop_deadline_ms == null) {
                self.log.message(.info, "stopping", "closing active connections; active={d}", .{self.counts.active});
                self.stop_deadline_ms = now;
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

test "stop signals close the listener once and release every connection phase" {
    var config = try Config.parse(std.testing.allocator,
        \\{"listen":"127.0.0.1:9443","routes":[{"sni":"example.com","backend":"127.0.0.1:9444"}],
        \\ "max_connections":4,"max_handshakes":4,"relay_buffer_bytes":4096,"stats_interval_ms":0}
    );
    defer config.deinit(std.testing.allocator);
    // The fixture binds an ephemeral port without changing public config validation.
    config.listen.ip4.port = 0;
    var log: logging.Logger = .{ .level = .none };
    var server = try Server.init(std.testing.allocator, &config, &log);
    var live = true;
    defer if (live) server.deinit();
    const server_fds = [_]i32{ server.listener, server.signals, server.epoll };
    var clients: [4]i32 = @splat(-1);
    var backends: [4]i32 = @splat(-1);
    var peers: [8]i32 = @splat(-1);
    defer for (peers) |fd| net.close(fd);
    var tokens: [4]u64 = undefined;
    const phases = [_]logging.Phase{ .hello, .connect, .prefix, .relay };
    for (phases, 0..) |phase, at| {
        var pair: [2]i32 = undefined;
        try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0, &pair)));
        clients[at] = pair[0];
        peers[at * 2] = pair[1];
        const index = server.pool.acquire().?;
        const staging = server.stages.acquire().?;
        const start = at * 8192;
        const slot = &server.slots[index];
        slot.* = .{
            .conn = Connection.init(pair[0], server.stage_slab[at * 65536 ..][0..65536], server.relay_slab[start..][0..4096], server.relay_slab[start + 4096 ..][0..4096], 0),
            .staging = staging,
        };
        server.counts.accepted += 1;
        server.counts.active += 1;
        if (phase != .hello) {
            try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0, &pair)));
            backends[at] = pair[0];
            peers[at * 2 + 1] = pair[1];
            slot.conn.backend = pair[0];
            slot.conn.route = &config.routes[0];
            slot.conn.state = if (phase == .connect) .connecting else .relaying;
            server.counts.routed += 1;
            slot.conn.stage_len = 2;
            slot.conn.stage_sent = 1;
        }
        if (phase == .relay) {
            slot.conn.stage = null;
            // Queued bytes must not be flushed or counted as forwarded at shutdown.
            slot.conn.to_backend.buffer.len = 1;
            slot.conn.to_client.buffer.len = 1;
        }
        try server.reconcile(index);
        tokens[at] = server.pool.token(index, false);
    }
    var pipe_fds: [4]i32 = @splat(-1);
    if (relay_pipe.enabled) {
        const pipes = server.io.openRelayPipes(4096) orelse return error.TestExpectedSharedPipes;
        for (pipes, 0..) |pipe, at| @memcpy(pipe_fds[at * 2 ..][0..2], &pipe.fds);
    }
    // Also cover a listener disarmed by accept backoff; integration covers the
    // ordinary registered listener through the real event loop.
    try control(server.epoll, linux.EPOLL.CTL_DEL, server.listener, 0, 0, &server.io.metrics);
    server.listener_registered = false;
    server.accept_resume_ms = std.math.maxInt(u64);
    const stop_now = try net.nowMs();
    // Target the blocked serving thread even if the test runner owns other threads.
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.tgkill(linux.getpid(), linux.gettid(), .TERM)));
    try server.signal(stop_now);
    try std.testing.expectEqual(@as(?u64, stop_now), server.stop_deadline_ms);
    try std.testing.expectEqual(@as(i32, -1), server.listener);
    try std.testing.expect(!server.listener_registered);
    try std.testing.expectEqual(linux.E.BADF, linux.errno(linux.fcntl(server_fds[0], linux.F.GETFD, 0)));
    // Repeated termination signals leave listener ownership and the stop request intact.
    for ([_]linux.SIG{ .TERM, .INT }) |sig| {
        try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.tgkill(linux.getpid(), linux.gettid(), sig)));
        try server.signal(stop_now + 1);
        try std.testing.expectEqual(@as(?u64, stop_now), server.stop_deadline_ms);
    }
    if (metrics.enabled) try std.testing.expectEqual(@as(u64, 1), server.io.metrics.get("close"));
    try server.run();
    try std.testing.expectEqual(@as(u64, 0), server.counts.active);
    try std.testing.expectEqual(@as(u64, 4), server.counts.closed);
    try std.testing.expectEqual(@as(u64, 0), server.counts.io_errors);
    try std.testing.expectEqual(@as(u64, 0), server.counts.timeouts);
    try std.testing.expectEqual(@as(u64, 0), server.counts.bytes_client_to_backend);
    try std.testing.expectEqual(@as(u64, 0), server.counts.bytes_backend_to_client);
    try std.testing.expectEqual(@as(usize, 0), server.timers.len);
    for (server.pool.entries, phases, tokens, clients, backends) |entry, phase, token, client, backend| {
        try std.testing.expect(!entry.used);
        try std.testing.expect(server.pool.resolve(token) == null);
        const index: u32 = @intCast((token >> 1) & 0xffff);
        try std.testing.expectEqual(.stopping, server.slots[index].conn.reason);
        try std.testing.expectEqual(phase, server.slots[index].conn.closed_phase);
        try std.testing.expectEqual(linux.E.BADF, linux.errno(linux.fcntl(client, linux.F.GETFD, 0)));
        if (backend >= 0) try std.testing.expectEqual(linux.E.BADF, linux.errno(linux.fcntl(backend, linux.F.GETFD, 0)));
    }
    for (server.stages.entries) |entry| try std.testing.expect(!entry.used);
    for (pipe_fds) |fd| if (fd >= 0) try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.fcntl(fd, linux.F.GETFD, 0)));
    if (metrics.enabled) try std.testing.expectEqual(@as(u64, 8), server.io.metrics.get("close"));
    server.deinit();
    live = false;
    for (server_fds) |fd| try std.testing.expectEqual(linux.E.BADF, linux.errno(linux.fcntl(fd, linux.F.GETFD, 0)));
    for (pipe_fds) |fd| if (fd >= 0) try std.testing.expectEqual(linux.E.BADF, linux.errno(linux.fcntl(fd, linux.F.GETFD, 0)));
    if (metrics.enabled and relay_pipe.enabled) {
        try std.testing.expectEqual(@as(u64, 0), server.io.metrics.get("pipe_live"));
        try std.testing.expectEqual(@as(u64, 12), server.io.metrics.get("close"));
    }
}
