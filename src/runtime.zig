//! One controller owns process signals. Each thread owns a complete Server.
const std = @import("std");
const linux = std.os.linux;
const net = @import("linux_io.zig");
const Config = @import("config.zig").Config;
const Server = @import("server.zig").Server;
const Signals = @import("signals.zig").Signals;
const logging = @import("log.zig");
const control = @import("worker_control.zig");
const metrics = @import("metrics.zig");

const Faults = struct { init_at: ?u8 = null, spawn_at: ?u8 = null, worker_at: ?u8 = null };

const Worker = struct {
    id: u8,
    config: Config, // Borrowed immutable routes/JSON; never deinit this view.
    log: logging.Logger,
    mailbox: control.Control,
    server: Server = undefined,
    thread: std.Thread = undefined,
    finished: std.atomic.Value(bool) = .init(false),
    failure: ?anyerror = null,
    final_value: control.Snapshot = .{},

    fn serve(self: *Worker, comptime faults: Faults) void {
        self.serveInner(faults) catch |err| {
            self.failure = err;
        };
        // A failed owner leaves the reuseport group before touching its pools.
        if (self.server.listener >= 0) {
            net.close(self.server.listener);
            self.server.io.metrics.add("close", 1);
            self.server.listener = -1;
            self.server.listener_registered = false;
        }
        self.server.deinit();
        self.log.flush();
        // Separate from requested snapshots: teardown must never overwrite a
        // snapshot while the controller is copying its published generation.
        self.final_value = .{ .counts = self.server.counts, .diagnostic = self.server.io.metrics };
        self.finished.store(true, .release);
        control.notify(self.mailbox.reply_fd) catch {};
    }

    fn serveInner(self: *Worker, comptime faults: Faults) !void {
        // Threads do not accept until every listener, pool and thread exists.
        while (true) {
            const flags = try self.mailbox.take();
            if (flags & control.stop != 0) return;
            if (flags & control.start != 0) {
                // A first SIGUSR1/2 can arrive while a new thread is still at
                // the gate. Preserve commands coalesced with START.
                const remaining = flags & ~control.start;
                if (remaining != 0) _ = self.mailbox.commands.fetchOr(remaining, .release);
                break;
            }
            var fds = [_]linux.pollfd{.{ .fd = self.mailbox.fd, .events = linux.POLL.IN, .revents = 0 }};
            try poll(&fds, -1);
        }
        if (faults.worker_at) |id| if (id == self.id) return error.InjectedWorkerFailure;
        self.mailbox.heartbeat.store(try net.nowMs(), .monotonic);
        try self.server.runWorker();
    }
};

pub const Runtime = struct {
    workers: [Config.max_workers]Worker = undefined,
    count: usize = 0,
    signals: ?Signals = null,
    reply_fd: i32 = -1,
    writer: control.Writer = undefined,
    other_errno: std.atomic.Value(u64) = .init(0),
    log: *logging.Logger = undefined,
    original_sink: logging.Sink = undefined,
    config: *const Config = undefined,
    epoch: u64 = 0,
    aggregate: control.Snapshot = .{},
    started: bool = false,
    released: bool = false,
    failure_info: ?struct { id: u8, cause: anyerror } = null,

    pub fn run(self: *Runtime, allocator: std.mem.Allocator, config: *const Config, log: *logging.Logger) !void {
        try self.start(allocator, config, log, .{});
        defer self.finish();
        const now = try net.nowMs();
        log.begin(now, &self.aggregate.counts);
        log.message(.info, "started", "listening on {s}; workers={d} capacity={d} handshakes={d} buffers={f}", .{
            config.raw.value.listen,                                        self.count, config.raw.value.max_connections, config.raw.value.max_handshakes,
            logging.Bytes{ .value = Config.bufferBytes(config.raw.value) },
        });
        self.started = true;
        try self.coordinate();
    }

    // Fault policy is comptime and only instantiated by tests. Shipping has no
    // environment/config test hooks and no injected branches in worker loops.
    fn start(self: *Runtime, allocator: std.mem.Allocator, config: *const Config, log: *logging.Logger, comptime faults: Faults) !void {
        std.debug.assert(config.raw.value.workers > 1 and self.count == 0);
        self.config = config;
        self.log = log;
        try net.checkWorkerFdLimit(config.raw.value.max_connections, config.raw.value.workers);
        self.original_sink = log.sink;
        self.writer = .{ .sink = log.sink };
        log.sink = .{ .context = &self.writer, .write = control.Writer.write };
        errdefer log.sink = self.original_sink;
        self.signals = try Signals.init();
        errdefer {
            self.signals.?.deinit();
            self.signals = null;
        }
        self.reply_fd = try control.createEvent();
        errdefer {
            net.close(self.reply_fd);
            self.reply_fd = -1;
        }
        errdefer self.stopAndJoin();
        const Entry = struct {
            fn run(worker: *Worker) void {
                worker.serve(faults);
            }
        };
        for (0..config.raw.value.workers) |i| {
            const id: u8 = @intCast(i);
            if (faults.init_at) |fail| if (id == fail) return error.InjectedWorkerInitFailure;
            const fd = try control.createEvent();
            errdefer net.close(fd);
            const worker = &self.workers[i];
            worker.* = .{
                .id = id,
                .config = config.*,
                .log = .{ .level = log.level, .format = log.format, .sink = log.sink, .worker_id = id, .other_errno = &self.other_errno },
                .mailbox = .{ .fd = fd, .reply_fd = self.reply_fd },
            };
            worker.config.raw.value.max_connections = control.share(config.raw.value.max_connections, config.raw.value.workers, id);
            worker.config.raw.value.max_handshakes = control.share(config.raw.value.max_handshakes, config.raw.value.workers, id);
            worker.config.raw.value.stats_interval_ms = 0;
            worker.config.raw.value.reuse_port = true;
            worker.mailbox.desired_level.store(@backingInt(log.level), .monotonic);
            worker.server = try Server.initWorker(allocator, &worker.config, &worker.log, &worker.mailbox);
            errdefer worker.server.deinit();
            if (faults.spawn_at) |fail| if (id == fail) return error.InjectedWorkerSpawnFailure;
            worker.thread = try std.Thread.spawn(.{}, Entry.run, .{worker});
            self.count += 1;
        }
    }

    fn release(self: *Runtime) !void {
        const now = try net.nowMs();
        for (self.workers[0..self.count]) |*worker| {
            worker.mailbox.heartbeat.store(now, .monotonic);
            try worker.mailbox.request(control.start);
        }
        self.released = true;
    }

    fn coordinate(self: *Runtime) !void {
        const Request = struct { explicit: bool, periodic: bool, level: ?logging.Level };
        var pending: ?Request = null;
        var explicit = false;
        var desired_level = self.log.level;
        const interval = self.config.raw.value.stats_interval_ms;
        var next_stats = (try net.nowMs()) +| interval;
        while (true) {
            const now = try net.nowMs();
            if (!self.released) for (self.workers[0..self.count]) |*worker| worker.mailbox.heartbeat.store(now, .monotonic);
            try self.checkWorkers(now);
            for (0..32) |_| {
                const signo = try self.signals.?.next() orelse break;
                if (signo == @backingInt(linux.SIG.INT) or signo == @backingInt(linux.SIG.TERM)) {
                    return;
                }
                if (signo == @backingInt(linux.SIG.USR1)) explicit = true;
                if (signo == @backingInt(linux.SIG.USR2)) desired_level = logging.nextLevel(desired_level);
            }
            if (!self.released) try self.release();
            if (pending) |request| {
                var ready = true;
                for (self.workers[0..self.count]) |*worker| {
                    if (worker.mailbox.published.load(.acquire) != self.epoch) ready = false;
                }
                if (ready) {
                    self.aggregate = .{};
                    for (self.workers[0..self.count]) |*worker| control.combine(&self.aggregate, worker.mailbox.value);
                    self.aggregate.counts.last_other_io_errno = self.other_errno.load(.monotonic);
                    if (request.periodic or request.level != null) self.log.periodic(now, &self.aggregate.counts);
                    if (request.level) |value| self.log.setLevel(value, now, &self.aggregate.counts, true);
                    if (request.explicit) {
                        self.log.snapshot(&self.aggregate.counts);
                        if (metrics.enabled) {
                            var storage: [metrics.capacity]u8 = undefined;
                            self.log.sink.write(self.log.sink.context, self.aggregate.diagnostic.snapshot(&storage));
                        }
                        for (self.workers[0..self.count]) |*worker| self.log.workerSnapshot(worker.id, &worker.mailbox.value.counts);
                    }
                    pending = null;
                }
            }
            const due = interval != 0 and now >= next_stats;
            if (pending == null and (explicit or due or desired_level != self.log.level)) {
                if (self.epoch == std.math.maxInt(u64)) return error.WorkerSnapshotGenerationExhausted;
                self.epoch += 1;
                pending = .{ .explicit = explicit, .periodic = due, .level = if (desired_level != self.log.level) desired_level else null };
                explicit = false;
                if (due) next_stats = now +| interval;
                for (self.workers[0..self.count]) |*worker| {
                    worker.mailbox.requested.store(self.epoch, .monotonic);
                    var flags = control.snapshot;
                    if (pending.?.level) |value| {
                        worker.mailbox.desired_level.store(@backingInt(value), .monotonic);
                        flags |= control.level;
                    }
                    try worker.mailbox.request(flags);
                }
            }
            var fds = [_]linux.pollfd{
                .{ .fd = self.signals.?.fd, .events = linux.POLL.IN, .revents = 0 },
                .{ .fd = self.reply_fd, .events = linux.POLL.IN, .revents = 0 },
            };
            const wake = if (interval == 0 or pending != null) now +| 1000 else @min(now +| 1000, next_stats);
            try poll(&fds, @intCast(wake -| now));
            if (fds[1].revents & linux.POLL.IN != 0) try control.drain(self.reply_fd);
        }
    }

    fn checkWorkers(self: *Runtime, now: u64) !void {
        for (self.workers[0..self.count]) |*worker| {
            if (worker.finished.load(.acquire)) {
                if (worker.failure) |failure| {
                    // Do not wait for a log mutex before broadcasting STOP:
                    // another owner may itself be stalled in its log sink.
                    self.failure_info = .{ .id = worker.id, .cause = failure };
                    return error.WorkerFailed;
                }
                return error.WorkerExitedUnexpectedly;
            }
            if (now -| worker.mailbox.heartbeat.load(.monotonic) > control.health_timeout_ms) std.process.exit(1);
        }
    }

    fn stopAndJoin(self: *Runtime) void {
        const deadline = (net.nowMs() catch std.process.exit(1)) +| control.health_timeout_ms;
        for (self.workers[0..self.count]) |*worker| {
            if (!worker.finished.load(.acquire)) worker.mailbox.request(control.stop) catch std.process.exit(1);
        }
        while (true) {
            var finished: usize = 0;
            for (self.workers[0..self.count]) |*worker| if (worker.finished.load(.acquire)) {
                finished += 1;
            };
            if (finished == self.count) break;
            if ((net.nowMs() catch std.process.exit(1)) >= deadline) std.process.exit(1);
            var fds = [_]linux.pollfd{.{ .fd = self.reply_fd, .events = linux.POLL.IN, .revents = 0 }};
            poll(&fds, 250) catch std.process.exit(1);
            control.drain(self.reply_fd) catch std.process.exit(1);
        }
        self.aggregate = .{};
        for (self.workers[0..self.count]) |*worker| {
            worker.thread.join();
            control.combine(&self.aggregate, worker.final_value);
            net.close(worker.mailbox.fd);
        }
        self.aggregate.counts.last_other_io_errno = self.other_errno.load(.monotonic);
        self.count = 0;
    }

    fn finish(self: *Runtime) void {
        self.stopAndJoin();
        if (self.failure_info) |failure| self.log.message(.@"error", "worker_failed", "worker={d} event loop failed: {s}", .{ failure.id, @errorName(failure.cause) });
        if (self.started) self.log.stopped(&self.aggregate.counts);
        net.close(self.reply_fd);
        self.reply_fd = -1;
        self.signals.?.deinit();
        self.signals = null;
        self.log.sink = self.original_sink;
    }
};

fn poll(fds: []linux.pollfd, timeout: i32) !void {
    const rc = linux.poll(fds.ptr, @intCast(fds.len), timeout);
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        .INTR => return,
        else => return error.WorkerPollFailed,
    }
    for (fds) |fd| if (fd.revents & (linux.POLL.ERR | linux.POLL.HUP | linux.POLL.NVAL) != 0) return error.WorkerControlFdFailed;
}

fn testConfig(allocator: std.mem.Allocator, storage: *[512]u8) !Config {
    const address = try @import("config.zig").Address.parseLiteral("127.0.0.1:0");
    const fd = try net.listen(address, false);
    defer net.close(fd);
    var bound: linux.sockaddr.in = std.mem.zeroes(linux.sockaddr.in);
    var length: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    if (linux.errno(linux.getsockname(fd, @ptrCast(&bound), &length)) != .SUCCESS) return error.TestSocketAddressFailed;
    const json = try std.mem.print(
        storage,
        "{{\"listen\":\"127.0.0.1:{d}\",\"fallback\":\"127.0.0.1:1\",\"routes\":[],\"workers\":2,\"max_connections\":8,\"max_handshakes\":4,\"stats_interval_ms\":0}}",
        .{std.mem.bigToNative(u16, bound.port)},
    );
    return Config.parse(allocator, json);
}

test "partial worker init and spawn failures join started threads and release listeners" {
    inline for ([_]Faults{ .{ .init_at = 1 }, .{ .spawn_at = 1 } }) |faults| {
        var storage: [512]u8 = undefined;
        var config = try testConfig(std.testing.allocator, &storage);
        defer config.deinit(std.testing.allocator);
        var log: logging.Logger = .{ .level = .none };
        var runtime: Runtime = .{};
        if (runtime.start(std.testing.allocator, &config, &log, faults)) |_| {
            runtime.finish();
            return error.ExpectedStartupFailure;
        } else |_| {}
        try std.testing.expectEqual(@as(usize, 0), runtime.count);
        const listener = try net.listen(config.listen, false);
        net.close(listener);
    }
}

test "worker error stops peers joins threads and releases the whole reuseport group" {
    var storage: [512]u8 = undefined;
    var config = try testConfig(std.testing.allocator, &storage);
    defer config.deinit(std.testing.allocator);
    var log: logging.Logger = .{ .level = .none };
    var runtime: Runtime = .{};
    try runtime.start(std.testing.allocator, &config, &log, .{ .worker_at = 0 });
    defer if (runtime.signals != null) runtime.finish();
    try runtime.release();
    try std.testing.expectError(error.WorkerFailed, runtime.coordinate());
    runtime.finish();
    const listener = try net.listen(config.listen, false);
    net.close(listener);
    try std.testing.expectEqual(@as(u64, 0), runtime.aggregate.counts.active);
}
