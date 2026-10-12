//! One process-wide signal scope, installed before any serving threads spawn.
const std = @import("std");
const linux = std.os.linux;
const net = @import("linux_io.zig");
const splice = @import("relay_pipe.zig").enabled;

pub const Signals = struct {
    fd: i32,
    previous_mask: linux.sigset_t,
    previous_sigpipe: if (splice) linux.Sigaction else void,

    pub fn init() !Signals {
        var mask = linux.sigemptyset();
        linux.sigaddset(&mask, .INT);
        linux.sigaddset(&mask, .TERM);
        linux.sigaddset(&mask, .USR1);
        linux.sigaddset(&mask, .USR2);
        var previous_mask: linux.sigset_t = undefined;
        if (linux.errno(linux.sigprocmask(linux.SIG.BLOCK, &mask, &previous_mask)) != .SUCCESS) return error.SignalMaskFailed;
        errdefer _ = linux.sigprocmask(linux.SIG.SETMASK, &previous_mask, null);
        const rc = linux.signalfd(-1, &mask, linux.SFD.NONBLOCK | linux.SFD.CLOEXEC);
        if (linux.errno(rc) != .SUCCESS) return error.SignalFdFailed;
        const fd: i32 = @intCast(rc);
        errdefer net.close(fd);
        var previous_sigpipe: if (splice) linux.Sigaction else void = undefined;
        if (splice) {
            const ignore: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.IGN }, .mask = linux.sigemptyset(), .flags = 0 };
            if (linux.errno(linux.sigaction(.PIPE, &ignore, &previous_sigpipe)) != .SUCCESS) return error.SigpipeIgnoreFailed;
        }
        return .{ .fd = fd, .previous_mask = previous_mask, .previous_sigpipe = previous_sigpipe };
    }

    pub fn deinit(self: *Signals) void {
        // Repeated stop signals may have arrived during worker teardown. They
        // must not become default-action signals when the original mask returns.
        for (0..32) |_| {
            const signo = self.next() catch break;
            if (signo == null) break;
        }
        net.close(self.fd);
        if (splice) _ = linux.sigaction(.PIPE, &self.previous_sigpipe, null);
        _ = linux.sigprocmask(linux.SIG.SETMASK, &self.previous_mask, null);
    }

    pub fn next(self: *const Signals) !?u32 {
        for (0..32) |_| {
            var info: linux.signalfd_siginfo = undefined;
            const bytes = std.mem.asBytes(&info);
            const rc = linux.read(self.fd, bytes.ptr, bytes.len);
            switch (linux.errno(rc)) {
                .SUCCESS => return if (rc == bytes.len) info.signo else error.SignalReadFailed,
                .AGAIN => return null,
                .INTR => continue,
                else => return error.SignalReadFailed,
            }
        }
        return null;
    }
};
