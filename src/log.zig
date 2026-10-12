//! Single-owner, fixed-buffer stderr logging. No packet or payload logging.
const std = @import("std");
const linux = std.os.linux;
const counters_mod = @import("counters.zig");
const Counters = counters_mod.Counters;
const outcome = @import("io_result.zig");

pub const Level = enum(u8) { none, @"error", warn, info, debug };
pub const Format = enum { text, json };
const message_capacity = 640;
const line_capacity = 4096;

pub const Bytes = struct {
    value: u64,
    two_decimals: bool = false,

    pub fn format(self: Bytes, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB" };
        var unit: usize = 0;
        var divisor: u64 = 1;
        while (unit < units.len - 1 and self.value / divisor >= 1024) : (unit += 1) divisor *= 1024;
        if (unit == 0) return writer.print("{d}B", .{self.value});
        if (self.two_decimals) {
            const fraction: u64 = @intCast(@as(u128, self.value % divisor) * 100 / divisor);
            try writer.print("{d}.{d:0>2}{s}", .{ self.value / divisor, fraction, units[unit] });
        } else {
            const fraction: u64 = @intCast(@as(u128, self.value % divisor) * 10 / divisor);
            try writer.print("{d}.{d}{s}", .{ self.value / divisor, fraction, units[unit] });
        }
    }
};

const Seconds = struct {
    ms: u64,

    pub fn format(self: Seconds, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.ms % 1000 == 0) return writer.print("{d}", .{self.ms / 1000});
        try writer.print("{d}.{d:0>3}", .{ self.ms / 1000, self.ms % 1000 });
    }
};

const Rate = struct {
    bytes: u64,
    elapsed_ms: u64,

    pub fn format(self: Rate, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB" };
        // The numerator is at most u64 * 1000; its remainder * 100 also fits.
        const numerator = @as(u128, self.bytes) * 1000;
        var divisor: u128 = @max(self.elapsed_ms, 1);
        var unit: usize = 0;
        while (unit < units.len - 1 and numerator / divisor >= 1024) : (unit += 1) divisor *= 1024;
        try writer.print("{d}.{d:0>2}{s}/s", .{ numerator / divisor, numerator % divisor * 100 / divisor, units[unit] });
    }
};

pub const Phase = enum { accept, hello, connect, prefix, relay, idle };
pub const Context = struct {
    phase: Phase,
    backend: ?std.Io.net.IpAddress = null,
    errno: ?linux.E = null,
    side: ?outcome.Side = null,
    operation: ?outcome.Operation = null,
};
pub const Warning = enum { connect_failures, connect_timeouts, prefix_timeouts, connection_capacity, handshake_capacity, accept_pressure, socket_setup, metadata_failed, network_failures };
const Warnings = struct {
    connect_failures: u64 = 0,
    connect_timeouts: u64 = 0,
    prefix_timeouts: u64 = 0,
    connection_capacity: u64 = 0,
    handshake_capacity: u64 = 0,
    accept_pressure: u64 = 0,
    socket_setup: u64 = 0,
    metadata_failed: u64 = 0,
    network_failures: u64 = 0,
};
const Errors = struct { other_io_errors: u64 = 0, zero_writes: u64 = 0 };
pub const Closed = struct {
    id: u64,
    lifetime_ms: u64,
    route: []const u8,
    reason: []const u8,
    context: Context,
    zero_write: bool = false,
    hello_timeout: bool = false,
};

/// The sink seam captures the production logger in unit tests. Serving uses stderr.
pub const Sink = struct {
    context: ?*anyopaque = null,
    write: *const fn (?*anyopaque, []const u8) void = writeStderr,
};

pub const Logger = struct {
    level: Level = .info,
    format: Format = .text,
    sink: Sink = .{},
    worker_id: ?u8 = null,
    // Multi-worker gauge publication occurs only for uncommon fatal I/O.
    other_errno: ?*std.atomic.Value(u64) = null,
    previous_activity: Counters = .{},
    previous_activity_ms: u64 = 0,
    pending_warning: Warnings = .{},
    last_warning: ?struct { kind: Warning, context: Context } = null,
    pending_error: Errors = .{},
    last_error: ?Context = null,
    warning_due_ms: u64 = 0,

    pub fn enabled(self: *const Logger, level: Level) bool {
        return level != .none and @backingInt(level) <= @backingInt(self.level);
    }

    pub fn begin(self: *Logger, now: u64, counts: *const Counters) void {
        self.previous_activity = counts.*;
        self.previous_activity_ms = now;
        self.pending_warning = .{};
        self.last_warning = null;
        self.pending_error = .{};
        self.last_error = null;
        self.warning_due_ms = now +| 1000;
    }

    pub fn message(self: *const Logger, level: Level, comptime event: []const u8, comptime fmt: []const u8, args: anytype) void {
        if (!self.enabled(level)) return;
        self.forceMessage(level, event, fmt, args);
    }

    fn forceMessage(self: *const Logger, level: Level, comptime event: []const u8, comptime fmt: []const u8, args: anytype) void {
        var body: [message_capacity]u8 = undefined;
        const msg: []const u8 = std.mem.print(&body, fmt, args) catch "message exceeds log limit";
        self.emit(level, event, msg);
    }

    fn emit(self: *const Logger, level: Level, comptime event: []const u8, body: []const u8) void {
        var line: [line_capacity]u8 = undefined;
        const bytes = render(self.format, level, event, body, wallSeconds(), &line);
        if (self.worker_id) |id| {
            if (self.format == .json) {
                const tail = std.mem.print(line[bytes.len - 2 ..], ",\"worker\":{d}}}\n", .{id}) catch unreachable;
                self.sink.write(self.sink.context, line[0 .. bytes.len - 2 + tail.len]);
            } else {
                // The prefix is fixed ASCII; insert an identity without touching
                // the escaped message or widening its formatting buffer.
                const prefix: usize = 27;
                var label: [16]u8 = undefined;
                const tag = std.mem.print(&label, "worker={d} | ", .{id}) catch unreachable;
                @memmove(line[prefix + tag.len ..][0 .. bytes.len - prefix], line[prefix..bytes.len]);
                @memcpy(line[prefix..][0..tag.len], tag);
                self.sink.write(self.sink.context, line[0 .. bytes.len + tag.len]);
            }
        } else self.sink.write(self.sink.context, bytes);
    }

    /// Record only cold failure paths; the full machine counters remain separate.
    pub fn warning(self: *Logger, kind: Warning, context: Context) void {
        if (!self.enabled(.warn)) return;
        inline for (@typeInfo(Warning).@"enum".field_names) |name| if (kind == @field(Warning, name)) {
            @field(self.pending_warning, name) +%= 1;
        };
        self.last_warning = .{ .kind = kind, .context = context };
    }

    pub fn ioFailure(self: *Logger, context: Context, failure: outcome.Failure) void {
        switch (failure) {
            .errno => |err| switch (err) {
                .CONNRESET, .PIPE => return,
                .NOTCONN, .CONNABORTED, .TIMEDOUT, .NETRESET, .NETDOWN, .NETUNREACH, .HOSTDOWN, .HOSTUNREACH, .NONET => {
                    self.warning(.network_failures, context);
                    return;
                },
                else => {
                    if (self.other_errno) |gauge| gauge.store(@backingInt(err), .monotonic);
                    if (!self.enabled(.@"error")) return;
                    self.pending_error.other_io_errors +%= 1;
                },
            },
            .zero_write => {
                if (!self.enabled(.@"error")) return;
                self.pending_error.zero_writes +%= 1;
            },
        }
        self.last_error = context;
    }

    /// Consume each batch once, with at most one line per severity per second.
    pub fn tick(self: *Logger, now: u64) void {
        if (now < self.warning_due_ms) return;
        self.flush();
        self.warning_due_ms = now +| 1000;
    }

    pub fn flush(self: *Logger) void {
        if (self.enabled(.warn)) if (group("warnings |", self.pending_warning, @typeInfo(Warnings).@"struct".field_names)) |value| {
            var body = value;
            if (self.last_warning) |last| {
                body.append(" | last: cause={s}", .{@tagName(last.kind)});
                appendContext(&body, last.context);
            }
            self.emit(.warn, "failures", body.slice());
        };
        if (self.enabled(.@"error")) if (group("socket failures |", self.pending_error, @typeInfo(Errors).@"struct".field_names)) |value| {
            var body = value;
            body.append(" | last:", .{});
            if (self.last_error) |context| appendContext(&body, context);
            self.emit(.@"error", "io_failure", body.slice());
        };
        self.pending_warning = .{};
        self.last_warning = null;
        self.pending_error = .{};
        self.last_error = null;
    }

    pub fn periodic(self: *Logger, now: u64, counts: *const Counters) void {
        // A level change can arrive in the same millisecond as a summary.
        // Retain its pending window rather than inventing an elapsed interval.
        if (now <= self.previous_activity_ms) return;
        const elapsed = now - self.previous_activity_ms;
        const changes = delta(counts.*, self.previous_activity);
        const changed = if (self.format == .json)
            !std.meta.eql(counts.*, self.previous_activity)
        else
            counts.active != self.previous_activity.active or
                counts.bytes_client_to_backend != self.previous_activity.bytes_client_to_backend or
                counts.bytes_backend_to_client != self.previous_activity.bytes_backend_to_client;
        self.previous_activity = counts.*;
        self.previous_activity_ms = now;
        if (!self.enabled(.info) or !changed) return;
        if (self.format == .json) return self.jsonSnapshot(counts);
        self.forceMessage(.info, "activity", "stats | active={d} | avg({f}s): up={f} down={f} | total: up={f} down={f}", .{
            counts.active,                                                           Seconds{ .ms = elapsed },
            Rate{ .bytes = changes.bytes_client_to_backend, .elapsed_ms = elapsed }, Rate{ .bytes = changes.bytes_backend_to_client, .elapsed_ms = elapsed },
            Bytes{ .value = counts.bytes_client_to_backend, .two_decimals = true },  Bytes{ .value = counts.bytes_backend_to_client, .two_decimals = true },
        });
    }

    pub fn stopped(self: *Logger, counts: *const Counters) void {
        self.flush();
        if (!self.enabled(.info)) return;
        self.forceMessage(.info, "stopped", "stopped | accepted={d} closed={d} | total: up={f} down={f}", .{
            counts.accepted,                                                        counts.closed,
            Bytes{ .value = counts.bytes_client_to_backend, .two_decimals = true }, Bytes{ .value = counts.bytes_backend_to_client, .two_decimals = true },
        });
        if (self.format == .json) self.jsonSnapshot(counts);
    }

    /// Explicit diagnostics bypass verbosity, including none; totals stay intact.
    pub fn snapshot(self: *const Logger, counts: *const Counters) void {
        if (self.format == .json) return self.jsonSnapshot(counts);
        self.forceMessage(.info, "stats", "totals active={d} accepted={d} routed={d} closed={d}", .{
            counts.active, counts.accepted, counts.routed, counts.closed,
        });
        self.forceMessage(.info, "stats", "traffic | total: up={f} down={f}", .{
            Bytes{ .value = counts.bytes_client_to_backend, .two_decimals = true }, Bytes{ .value = counts.bytes_backend_to_client, .two_decimals = true },
        });
        const Group = struct { title: []const u8, fields: []const []const u8 };
        inline for ([_]Group{
            .{ .title = "routing", .fields = &.{ "fallback_routed", "unknown_sni", "missing_sni", "invalid_client_hello" } },
            .{ .title = "failures", .fields = &.{ "connect_failures", "timeouts", "rejected", "accept_errors" } },
            .{ .title = "socket causes", .fields = &.{ "io_errors", "connection_resets", "broken_pipes", "not_connected", "connection_aborts", "socket_timeouts", "network_errors", "other_io_errors", "zero_writes" } },
            .{ .title = "client socket", .fields = &.{ "client_read_errors", "client_write_errors", "client_shutdown_errors", "client_socket_errors" } },
            .{ .title = "backend socket", .fields = &.{ "backend_read_errors", "backend_write_errors", "backend_shutdown_errors", "backend_socket_errors" } },
            .{ .title = "last errno", .fields = &.{"last_other_io_errno"} },
        }) |fields| {
            if (group(fields.title, counts.*, fields.fields)) |body| self.emit(.info, "stats", body.slice());
        }
    }

    fn jsonSnapshot(self: *const Logger, counts: *const Counters) void {
        var bytes: [counters_mod.snapshot_capacity]u8 = undefined;
        self.sink.write(self.sink.context, counts.snapshot(&bytes));
    }

    /// One final lifecycle record; route names refer only to immutable config.
    pub fn closed(self: *const Logger, detail: Closed) void {
        if (!self.enabled(.debug)) return;
        // A configured DNS name is at most 253 bytes; CloseReason tags fit 32.
        std.debug.assert(detail.route.len <= 253 and detail.reason.len <= 32);
        comptime {
            if (253 + 32 + 20 + 24 + 100 + 160 + 20 > message_capacity) @compileError("Close context exceeds log message buffer");
        }
        var body: Message = .{};
        body.append("connection id={d} | closed | duration={f}s | route={s} | reason={s}", .{
            detail.id, Seconds{ .ms = detail.lifetime_ms }, detail.route, if (detail.zero_write) "zero_write" else detail.reason,
        });
        appendContext(&body, detail.context);
        if (detail.hello_timeout) body.append(" hello_timeout=true", .{});
        self.emit(.debug, "connection_closed", body.slice());
    }

    /// A temporary runtime setting; a restart restores the configuration value.
    pub fn cycle(self: *Logger, now: u64, counts: *const Counters) void {
        self.flush();
        self.periodic(now, counts);
        self.level = nextLevel(self.level);
        self.begin(now, counts); // Do not replay errors accumulated while muted.
        self.forceMessage(.info, "log_level", "log level changed to {s}", .{@tagName(self.level)});
    }

    pub fn setLevel(self: *Logger, value: Level, now: u64, counts: *const Counters, announce: bool) void {
        self.flush();
        self.level = value;
        self.begin(now, counts);
        if (announce) self.forceMessage(.info, "log_level", "log level changed to {s}", .{@tagName(value)});
    }

    pub fn workerSnapshot(self: *const Logger, id: u8, counts: *const Counters) void {
        self.forceMessage(.debug, "worker_stats", "worker={d} active={d} accepted={d} routed={d} closed={d} rejected={d} io_errors={d} up={d} down={d}", .{
            id, counts.active, counts.accepted, counts.routed, counts.closed, counts.rejected, counts.io_errors, counts.bytes_client_to_backend, counts.bytes_backend_to_client,
        });
    }
};

pub fn nextLevel(value: Level) Level {
    return switch (value) {
        .info => .debug,
        .debug => .none,
        .none => .@"error",
        .@"error" => .warn,
        .warn => .info,
    };
}

const Message = struct {
    bytes: [message_capacity]u8 = undefined,
    len: usize = 0,

    fn append(self: *Message, comptime fmt: []const u8, args: anytype) void {
        const part = std.mem.print(self.bytes[self.len..], fmt, args) catch unreachable;
        self.len += part.len;
    }

    fn slice(self: *const Message) []const u8 {
        return self.bytes[0..self.len];
    }
};

fn group(comptime title: []const u8, counts: anytype, comptime fields: anytype) ?Message {
    comptime {
        var bound = title.len;
        for (fields) |field_name| bound += field_name.len + 2 + 20;
        // Reserve the longest last-event context (phase, endpoint, side/op/errno).
        if (bound > message_capacity - 208) @compileError("Counter group exceeds log message buffer");
    }
    var body: Message = .{};
    body.append("{s}", .{title});
    var nonzero = false;
    inline for (fields) |field_name| {
        const value = @field(counts, field_name);
        if (value != 0) {
            nonzero = true;
            body.append(" " ++ field_name ++ "={d}", .{value});
        }
    }
    return if (nonzero) body else null;
}

fn appendContext(body: *Message, context: Context) void {
    body.append(" phase={s}", .{@tagName(context.phase)});
    if (context.backend) |backend| body.append(" backend={f}", .{backend});
    if (context.side) |side| body.append(" side={s}", .{@tagName(side)});
    if (context.operation) |operation| body.append(" operation={s}", .{@tagName(operation)});
    if (context.errno) |err| body.append(" errno={d}({s})", .{ @backingInt(err), std.enums.tagName(linux.E, err) orelse "UNKNOWN" });
}

fn delta(current: Counters, previous: Counters) Counters {
    var result = current;
    inline for (@typeInfo(Counters).@"struct".field_names) |field_name| {
        if (comptime !std.mem.eql(u8, field_name, "active") and !std.mem.eql(u8, field_name, "last_other_io_errno")) {
            @field(result, field_name) = @field(current, field_name) -% @field(previous, field_name);
        }
    }
    return result;
}

fn wallSeconds() u64 {
    var time: linux.timespec = undefined;
    if (linux.errno(linux.clock_gettime(.REALTIME, &time)) != .SUCCESS or time.sec < 0) return 0;
    // Keep calendar conversion bounded even if the host's wall clock is corrupt.
    return @min(@as(u64, @intCast(time.sec)), 253402300799); // 9999-12-31
}

fn render(format: Format, level: Level, comptime event: []const u8, body: []const u8, seconds: u64, out: *[line_capacity]u8) []const u8 {
    comptime {
        if (event.len > 64) @compileError("Log event name exceeds fixed prefix allowance");
        for (event) |byte| {
            if (!std.ascii.isAlphanumeric(byte) and byte != '_') @compileError("Log event names must be ASCII identifiers");
        }
        if (message_capacity * 6 + 192 > line_capacity) @compileError("Escaped log message exceeds line buffer");
    }
    std.debug.assert(body.len <= message_capacity);
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = seconds };
    const date = epoch.getEpochDay().calculateYearDay();
    const month = date.calculateMonthDay();
    const time = epoch.getDaySeconds();
    var stamp: [20]u8 = undefined;
    const timestamp = std.mem.print(&stamp, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        date.year,              month.month.numeric(),     @as(u8, month.day_index) + 1,
        time.getHoursIntoDay(), time.getMinutesIntoHour(), time.getSecondsIntoMinute(),
    }) catch unreachable;
    const label = switch (level) {
        .none => "NONE",
        .@"error" => "ERROR",
        .warn => "WARN",
        .info => "INFO",
        .debug => "DEBUG",
    };
    const prefix = if (format == .text)
        std.mem.print(out, "{s} {s: <5} ", .{ timestamp, label }) catch unreachable
    else
        std.mem.print(out, "{{\"time\":\"{s}\",\"level\":\"{s}\",\"event\":\"{s}\",\"message\":\"", .{ timestamp, @tagName(level), event }) catch unreachable;
    var len = prefix.len;
    const hex = "0123456789abcdef";
    for (body) |byte| {
        if (byte < 32 or byte == 127 or (format == .json and (byte == '"' or byte == '\\'))) {
            const escaped = if (format == .json and (byte == '"' or byte == '\\'))
                std.mem.print(out[len..], "\\{c}", .{byte}) catch unreachable
            else if (format == .json)
                std.mem.print(out[len..], "\\u00{c}{c}", .{ hex[byte >> 4], hex[byte & 15] }) catch unreachable
            else
                std.mem.print(out[len..], "\\x{c}{c}", .{ hex[byte >> 4], hex[byte & 15] }) catch unreachable;
            len += escaped.len;
        } else {
            out[len] = byte;
            len += 1;
        }
    }
    const suffix = if (format == .json) "\"}\n" else "\n";
    @memcpy(out[len..][0..suffix.len], suffix);
    return out[0 .. len + suffix.len];
}

fn writeStderr(_: ?*anyopaque, bytes: []const u8) void {
    var offset: usize = 0;
    while (offset < bytes.len) {
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

test "log lines escape controls and JSON injection within the maximum buffer" {
    var out: [line_capacity]u8 = undefined;
    const payload = "bad\n\"event\":\"forged\"\\\x1b";
    const text = render(.text, .warn, "test", payload, 0, &out);
    try std.testing.expect(std.mem.startsWith(u8, text, "1970-01-01T00:00:00Z WARN  "));
    try std.testing.expect(std.mem.findScalar(u8, text[0 .. text.len - 1], '\n') == null);
    try std.testing.expect(std.mem.findScalar(u8, text, 27) == null);
    const hostile: [message_capacity]u8 = @splat(1);
    const json = render(.json, .@"error", "test", &hostile, 0, &out);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(&hostile, parsed.value.object.get("message").?.string);
    const injected = render(.json, .warn, "test", payload, 0, &out);
    const result = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, injected, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings("test", result.value.object.get("event").?.string);
    try std.testing.expectEqualStrings(payload, result.value.object.get("message").?.string);
}

const Capture = struct {
    bytes: [16384]u8 = undefined,
    len: usize = 0,
    fn write(context: ?*anyopaque, bytes: []const u8) void {
        const self: *Capture = @ptrCast(@alignCast(context.?));
        @memcpy(self.bytes[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }
    fn slice(self: *const Capture) []const u8 {
        return self.bytes[0..self.len];
    }
};

test "worker identity is escaped bounded metadata in text and JSON" {
    var capture: Capture = .{};
    var logger: Logger = .{ .worker_id = 15, .sink = .{ .context = &capture, .write = Capture.write } };
    logger.message(.info, "test", "message\n", .{});
    try std.testing.expect(std.mem.find(u8, capture.slice(), "worker=15 | message\\x0a") != null);
    capture.len = 0;
    logger.format = .json;
    logger.message(.info, "test", "message\n", .{});
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, capture.slice(), .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 15), parsed.value.object.get("worker").?.integer);
    try std.testing.expectEqualStrings("message\n", parsed.value.object.get("message").?.string);
}

test "logger consumes deltas once, limits bursts, filters severity and skips idle" {
    var capture: Capture = .{};
    var logger: Logger = .{ .sink = .{ .context = &capture, .write = Capture.write } };
    var counts: Counters = .{};
    logger.begin(0, &counts);
    logger.periodic(1, &counts);
    try std.testing.expectEqual(@as(usize, 0), capture.len);
    counts.connect_failures = 7;
    counts.connection_resets = 66;
    counts.broken_pipes = 6;
    for (0..7) |_| logger.warning(.connect_failures, .{ .phase = .connect, .errno = .CONNREFUSED });
    logger.ioFailure(.{ .phase = .relay, .errno = .CONNRESET }, .{ .errno = .CONNRESET });
    logger.ioFailure(.{ .phase = .relay, .errno = .PIPE }, .{ .errno = .PIPE });
    logger.tick(999);
    try std.testing.expectEqual(@as(usize, 0), capture.len);
    logger.tick(1000);
    try std.testing.expect(std.mem.find(u8, capture.slice(), "WARN  warnings | connect_failures=7 | last: cause=connect_failures phase=connect errno=111(CONNREFUSED)") != null);
    try std.testing.expect(std.mem.find(u8, capture.slice(), "connection_resets") == null);
    const once = capture.len;
    logger.tick(2000);
    try std.testing.expectEqual(once, capture.len);
    logger.level = .@"error";
    counts.connect_failures += 1;
    counts.other_io_errors = 1;
    counts.last_other_io_errno = 4090;
    logger.warning(.connect_failures, .{ .phase = .connect });
    logger.ioFailure(.{ .phase = .relay, .errno = @fromBackingInt(4090) }, .{ .errno = @fromBackingInt(4090) });
    logger.tick(3000);
    try std.testing.expect(std.mem.find(u8, capture.slice()[once..], "ERROR socket failures | other_io_errors=1 | last: phase=relay errno=4090(UNKNOWN)") != null);
    try std.testing.expect(std.mem.find(u8, capture.slice()[once..], "connect_failures") == null);
    logger.level = .none;
    const muted = capture.len;
    logger.message(.@"error", "test", "fatal", .{});
    logger.periodic(4000, &counts);
    logger.stopped(&counts);
    try std.testing.expectEqual(muted, capture.len);
    logger.snapshot(&counts);
    try std.testing.expect(capture.len > muted);
}

test "maximum-width text totals, byte units and wrapping deltas stay bounded" {
    var capture: Capture = .{};
    var logger: Logger = .{ .level = .debug, .sink = .{ .context = &capture, .write = Capture.write } };
    var counts: Counters = .{};
    inline for (@typeInfo(Counters).@"struct".field_names) |field_name| @field(counts, field_name) = std.math.maxInt(u64);
    logger.snapshot(&counts);
    logger.periodic(1, &counts);
    try std.testing.expect(std.mem.find(u8, capture.slice(), "15.99EiB") != null);
    const endpoint: std.Io.net.IpAddress = .{ .ip6 = .{ .bytes = @splat(255), .port = 65535 } };
    const context: Context = .{ .phase = .connect, .backend = endpoint, .errno = .NOTRECOVERABLE, .side = .backend, .operation = .socket_error };
    inline for (@typeInfo(Warnings).@"struct".field_names) |field_name| @field(logger.pending_warning, field_name) = std.math.maxInt(u64);
    logger.last_warning = .{ .kind = .connection_capacity, .context = context };
    logger.flush();
    const route: [253]u8 = @splat('a');
    logger.closed(.{ .id = std.math.maxInt(u64), .lifetime_ms = std.math.maxInt(u64), .route = &route, .reason = "proxy_metadata_failed", .context = context, .hello_timeout = true });
    try std.testing.expect(std.mem.find(u8, capture.slice(), "message exceeds log limit") == null);
    try std.testing.expect(std.mem.find(u8, capture.slice(), "hello_timeout=true") != null);
    counts.accepted = 2;
    const changes = delta(counts, .{ .accepted = std.math.maxInt(u64) });
    try std.testing.expectEqual(@as(u64, 3), changes.accepted);
    try std.testing.expectEqual(counts.active, changes.active);
    try std.testing.expectEqual(counts.last_other_io_errno, changes.last_other_io_errno);
}

test "level changes flush visible pending failures without replaying muted counts" {
    var capture: Capture = .{};
    var logger: Logger = .{ .sink = .{ .context = &capture, .write = Capture.write } };
    var counts: Counters = .{ .accepted = 3, .closed = 3, .connect_failures = 3, .bytes_client_to_backend = 4096 };
    for (0..3) |_| logger.warning(.connect_failures, .{ .phase = .connect });
    logger.cycle(10, &counts); // info -> debug: preserve the current interval.
    try std.testing.expect(std.mem.find(u8, capture.slice(), "connect_failures=3") != null);
    try std.testing.expect(std.mem.find(u8, capture.slice(), "stats | active=0 | avg(0.010s)") != null);
    logger.cycle(20, &counts); // debug -> none
    counts.accepted += 7;
    counts.closed += 7;
    counts.connect_failures += 7;
    for (0..7) |_| logger.warning(.connect_failures, .{ .phase = .connect });
    const muted = capture.len;
    logger.cycle(30, &counts); // none -> error
    logger.cycle(40, &counts); // error -> warn
    logger.cycle(50, &counts); // warn -> info
    logger.tick(2000);
    logger.periodic(2000, &counts);
    const resumed = capture.slice()[muted..];
    try std.testing.expect(std.mem.find(u8, resumed, "connect_failures=") == null);
    try std.testing.expect(std.mem.find(u8, resumed, "stats |") == null);
}

test "traffic totals accumulate and rates use actual elapsed time without repeating an idle active connection" {
    var capture: Capture = .{};
    var logger: Logger = .{ .sink = .{ .context = &capture, .write = Capture.write } };
    var counts: Counters = .{};
    logger.begin(100, &counts);
    counts.active = 1;
    counts.accepted = 1;
    counts.bytes_client_to_backend = 12800;
    counts.bytes_backend_to_client = 25600;
    logger.periodic(100, &counts); // No invented rate or lost data at zero elapsed.
    try std.testing.expectEqual(@as(usize, 0), capture.len);
    logger.periodic(12600, &counts);
    try std.testing.expect(std.mem.find(u8, capture.slice(), "stats | active=1 | avg(12.500s): up=1.00KiB/s down=2.00KiB/s | total: up=12.50KiB down=25.00KiB") != null);
    const first = capture.len;
    counts.bytes_client_to_backend += 5120;
    counts.bytes_backend_to_client += 10240;
    logger.periodic(22600, &counts);
    try std.testing.expect(std.mem.find(u8, capture.slice()[first..], "avg(10s): up=512.00B/s down=1.00KiB/s | total: up=17.50KiB down=35.00KiB") != null);
    const stable = capture.len;
    logger.periodic(32600, &counts);
    counts.accepted += 1;
    counts.closed += 1;
    counts.timeouts += 1;
    logger.periodic(42600, &counts);
    try std.testing.expectEqual(stable, capture.len);
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("0.25B/s", try std.mem.print(&buffer, "{f}", .{Rate{ .bytes = 1, .elapsed_ms = 4000 }}));
}

test "periodic JSON preserves every original machine counter and exact bytes" {
    var capture: Capture = .{};
    var logger: Logger = .{ .format = .json, .sink = .{ .context = &capture, .write = Capture.write } };
    const counts: Counters = .{ .active = 1, .bytes_client_to_backend = 12345, .bytes_backend_to_client = 67890, .timeouts = 7 };
    logger.periodic(30000, &counts);
    var buffer: [counters_mod.snapshot_capacity]u8 = undefined;
    try std.testing.expectEqualStrings(counts.snapshot(&buffer), capture.slice());
    const stable = capture.len;
    logger.periodic(60000, &counts);
    try std.testing.expectEqual(stable, capture.len);
}
