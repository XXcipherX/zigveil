const std = @import("std");
const linux = std.os.linux;
const net = @import("linux_io.zig");
const Config = @import("config.zig").Config;
const Server = @import("server.zig").Server;
const Logger = @import("log.zig").Logger;

// Minimal keeps startup I/O explicit; hostname resolution ends before serving.
pub fn main(init: std.process.Init.Minimal) u8 {
    var log: Logger = .{};
    run(init, &log) catch |err| {
        if (err != error.ConfigReadFailed and err != error.ConfigValidationFailed)
            log.message(.@"error", "fatal", "zigveil: {s}", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn run(init: std.process.Init.Minimal, log: *Logger) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const args = try init.args.toSlice(allocator);
    if (args.len == 2 and std.mem.eql(u8, args[1], "--version")) {
        net.print("zigveil 0.1.0 (Zig 0.17.0, Linux epoll)\n", .{});
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--help")) {
        net.print("Usage: zigveil CONFIG.json\n       zigveil --check CONFIG.json\n       zigveil --help | --version\nSIGUSR1 prints totals; SIGUSR2 cycles info/debug/none/error/warn.\nSIGTERM/SIGINT drain for up to 30 seconds.\n", .{});
        return;
    }
    const check = args.len == 3 and std.mem.eql(u8, args[1], "--check");
    if ((!check and args.len != 2) or (args.len == 2 and std.mem.startsWith(u8, args[1], "--"))) return error.UsageZigveilConfigJsonOrCheckConfigJson;
    const path = args[if (check) @as(usize, 2) else 1];
    const text = readConfig(allocator, path) catch |err| {
        log.message(.@"error", "config_error", "zigveil: cannot read config {s}: {s}", .{ path, @errorName(err) });
        return error.ConfigReadFailed;
    };
    var config = Config.parse(allocator, text) catch |err| {
        log.message(.@"error", "config_error", "zigveil: invalid config {s}: {s}", .{ path, @errorName(err) });
        return error.ConfigValidationFailed;
    };
    defer config.deinit(allocator);
    log.level = if (check) .info else config.raw.value.log_level;
    log.format = config.raw.value.log_format;
    try net.checkFdLimit(config.raw.value.max_connections);
    if (check) {
        net.print("zigveil: config valid; routes={d} buffers={d} bytes; fd limit sufficient\n", .{ config.routes.len, Config.bufferBytes(config.raw.value) });
        return;
    }
    var server = try Server.init(std.heap.page_allocator, &config, log);
    defer server.deinit();
    try server.run();
}

fn readConfig(allocator: std.mem.Allocator, path: [:0]const u8) ![]const u8 {
    const rc = linux.openat(linux.AT.FDCWD, path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NONBLOCK = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.OpenFailed;
    const fd: i32 = @intCast(rc);
    defer net.close(fd);
    const bytes = try allocator.alloc(u8, 1024 * 1024 + 1);
    var length: usize = 0;
    while (length < bytes.len) {
        const n = linux.read(fd, bytes[length..].ptr, bytes.len - length);
        switch (linux.errno(n)) {
            .SUCCESS => {
                if (n == 0) return bytes[0..length];
                length += n;
            },
            .INTR => continue,
            else => return error.ReadFailed,
        }
    }
    return error.ConfigExceeds1MiB;
}
