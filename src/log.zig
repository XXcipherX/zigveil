//! Single-owner, fixed-buffer stderr logging. No packet or payload logging.
const std = @import("std");
const linux = std.os.linux;
const counters_mod = @import("counters.zig");
const Counters = counters_mod.Counters;

pub const Level = enum { none, @"error", warn, info, debug };
pub const Format = enum { text, json };
const message_capacity = 512;
const line_capacity = 4096;

pub const Bytes = struct {
    value: u64,

    pub fn format(self: Bytes, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB" };
        var unit: usize = 0;
        var divisor: u64 = 1;
        while (unit < units.len - 1 and self.value / divisor >= 1024) : (unit += 1) divisor *= 1024;
        if (unit == 0) return writer.print("{d}B", .{self.value});
        const fraction: u64 = @intCast(@as(u128, self.value % divisor) * 10 / divisor);
        try writer.print("{d}.{d}{s}", .{ self.value / divisor, fraction, units[unit] });
    }
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
    previous_activity: Counters = .{},
    previous_warning: Counters = .{},
    warning_due_ms: u64 = 0,

    pub fn enabled(self: *const Logger, level: Level) bool {
        return level != .none and @backingInt(level) <= @backingInt(self.level);
    }

    pub fn begin(self: *Logger, now: u64, counts: *const Counters) void {
        self.previous_activity = counts.*;
        self.previous_warning = counts.*;
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
        self.sink.write(self.sink.context, render(self.format, level, event, body, wallSeconds(), &line));
    }

    /// Consume each error delta once, with at most one line per severity per second.
    pub fn tick(self: *Logger, now: u64, counts: *const Counters) void {
        if (now < self.warning_due_ms) return;
        self.flush(counts);
        self.warning_due_ms = now +| 1000;
    }

    pub fn flush(self: *Logger, counts: *const Counters) void {
        const changes = delta(counts.*, self.previous_warning);
        self.previous_warning = counts.*;
        if (self.enabled(.warn)) if (group("failures", changes, &.{
            "connect_failures", "timeouts",          "rejected",        "accept_errors",  "invalid_client_hello",
            "not_connected",    "connection_aborts", "socket_timeouts", "network_errors",
        })) |body| self.emit(.warn, "failures", body.slice());
        if (self.enabled(.@"error")) if (group("socket failures", changes, &.{ "other_io_errors", "zero_writes" })) |value| {
            var body = value;
            if (changes.other_io_errors != 0) body.append(" last_other_io_errno={d}", .{counts.last_other_io_errno});
            self.emit(.@"error", "io_failure", body.slice());
        };
    }

    pub fn periodic(self: *Logger, counts: *const Counters) void {
        const changes = delta(counts.*, self.previous_activity);
        const changed = !std.meta.eql(counts.*, self.previous_activity);
        self.previous_activity = counts.*;
        if (!self.enabled(.info) or (!changed and counts.active == 0)) return;
        if (self.format == .json) return self.jsonSnapshot(counts);
        const body = activity(changes);
        self.forceMessage(.info, "activity", "activity; {s}", .{body.slice()});
    }

    pub fn stopped(self: *Logger, counts: *const Counters) void {
        self.flush(counts);
        if (!self.enabled(.info)) return;
        const body = activity(counts.*);
        self.forceMessage(.info, "stopped", "stopped; {s}", .{body.slice()});
        if (self.format == .json) self.jsonSnapshot(counts);
    }

    /// Explicit diagnostics bypass verbosity, including none; totals stay intact.
    pub fn snapshot(self: *const Logger, counts: *const Counters) void {
        if (self.format == .json) return self.jsonSnapshot(counts);
        self.forceMessage(.info, "stats", "totals active={d} accepted={d} routed={d} closed={d}", .{
            counts.active, counts.accepted, counts.routed, counts.closed,
        });
        self.forceMessage(.info, "stats", "traffic sent={f} received={f}", .{
            Bytes{ .value = counts.bytes_client_to_backend }, Bytes{ .value = counts.bytes_backend_to_client },
        });
        const Group = struct { title: []const u8, fields: []const []const u8 };
        inline for ([_]Group{
            .{ .title = "routing", .fields = &.{ "unknown_sni", "missing_sni", "invalid_client_hello" } },
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

    /// A temporary runtime setting; a restart restores the configuration value.
    pub fn cycle(self: *Logger, now: u64, counts: *const Counters) void {
        self.flush(counts);
        self.periodic(counts);
        self.level = switch (self.level) {
            .info => .debug,
            .debug => .none,
            .none => .@"error",
            .@"error" => .warn,
            .warn => .info,
        };
        self.begin(now, counts); // Do not replay errors accumulated while muted.
        self.forceMessage(.info, "log_level", "log level changed to {s}", .{@tagName(self.level)});
    }
};

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

fn group(comptime title: []const u8, counts: Counters, comptime fields: []const []const u8) ?Message {
    comptime {
        var bound = title.len;
        for (fields) |field_name| bound += field_name.len + 2 + 20;
        if (bound > message_capacity - 48) @compileError("Counter group exceeds log message buffer");
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

fn activity(counts: Counters) Message {
    var body: Message = .{};
    body.append("active={d}", .{counts.active});
    inline for (.{ "accepted", "routed", "closed" }) |field_name| {
        if (@field(counts, field_name) != 0) body.append(" " ++ field_name ++ "={d}", .{@field(counts, field_name)});
    }
    if (counts.bytes_client_to_backend != 0) body.append(" sent={f}", .{Bytes{ .value = counts.bytes_client_to_backend }});
    if (counts.bytes_backend_to_client != 0) body.append(" received={f}", .{Bytes{ .value = counts.bytes_backend_to_client }});
    inline for (.{ "connection_resets", "broken_pipes", "unknown_sni", "missing_sni" }) |field_name| {
        if (@field(counts, field_name) != 0) body.append(" " ++ field_name ++ "={d}", .{@field(counts, field_name)});
    }
    return body;
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

test "logger consumes deltas once, limits bursts, filters severity and skips idle" {
    var capture: Capture = .{};
    var logger: Logger = .{ .sink = .{ .context = &capture, .write = Capture.write } };
    var counts: Counters = .{};
    logger.begin(0, &counts);
    logger.periodic(&counts);
    try std.testing.expectEqual(@as(usize, 0), capture.len);
    counts.connect_failures = 7;
    counts.connection_resets = 66;
    counts.broken_pipes = 6;
    logger.tick(999, &counts);
    try std.testing.expectEqual(@as(usize, 0), capture.len);
    logger.tick(1000, &counts);
    try std.testing.expect(std.mem.find(u8, capture.slice(), "WARN  failures connect_failures=7") != null);
    try std.testing.expect(std.mem.find(u8, capture.slice(), "connection_resets") == null);
    const once = capture.len;
    logger.tick(2000, &counts);
    try std.testing.expectEqual(once, capture.len);
    logger.level = .@"error";
    counts.connect_failures += 1;
    counts.other_io_errors = 1;
    counts.last_other_io_errno = 4090;
    logger.tick(3000, &counts);
    try std.testing.expect(std.mem.find(u8, capture.slice()[once..], "ERROR socket failures other_io_errors=1 last_other_io_errno=4090") != null);
    try std.testing.expect(std.mem.find(u8, capture.slice()[once..], "connect_failures") == null);
    logger.level = .none;
    const muted = capture.len;
    logger.message(.@"error", "test", "fatal", .{});
    logger.periodic(&counts);
    logger.stopped(&counts);
    try std.testing.expectEqual(muted, capture.len);
    logger.snapshot(&counts);
    try std.testing.expect(capture.len > muted);
}

test "maximum-width text totals, byte units and wrapping deltas stay bounded" {
    var capture: Capture = .{};
    const logger: Logger = .{ .sink = .{ .context = &capture, .write = Capture.write } };
    var counts: Counters = .{};
    inline for (@typeInfo(Counters).@"struct".field_names) |field_name| @field(counts, field_name) = std.math.maxInt(u64);
    logger.snapshot(&counts);
    const summary = activity(counts);
    try std.testing.expect(summary.len <= message_capacity);
    try std.testing.expect(std.mem.find(u8, summary.slice(), "15.9EiB") != null);
    counts.accepted = 2;
    const changes = delta(counts, .{ .accepted = std.math.maxInt(u64) });
    try std.testing.expectEqual(@as(u64, 3), changes.accepted);
    try std.testing.expectEqual(counts.active, changes.active);
    try std.testing.expectEqual(counts.last_other_io_errno, changes.last_other_io_errno);
}

test "level changes flush visible pending failures without replaying muted counts" {
    var capture: Capture = .{};
    var logger: Logger = .{ .sink = .{ .context = &capture, .write = Capture.write } };
    var counts: Counters = .{ .accepted = 3, .closed = 3, .connect_failures = 3 };
    logger.cycle(10, &counts); // info -> debug: preserve the current interval.
    try std.testing.expect(std.mem.find(u8, capture.slice(), "connect_failures=3") != null);
    try std.testing.expect(std.mem.find(u8, capture.slice(), "activity; active=0 accepted=3 closed=3") != null);
    logger.cycle(20, &counts); // debug -> none
    counts.accepted += 7;
    counts.closed += 7;
    counts.connect_failures += 7;
    const muted = capture.len;
    logger.cycle(30, &counts); // none -> error
    logger.cycle(40, &counts); // error -> warn
    logger.cycle(50, &counts); // warn -> info
    logger.tick(2000, &counts);
    logger.periodic(&counts);
    const resumed = capture.slice()[muted..];
    try std.testing.expect(std.mem.find(u8, resumed, "connect_failures=") == null);
    try std.testing.expect(std.mem.find(u8, resumed, "activity;") == null);
}
