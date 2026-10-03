//! Process-owned handles and callback-local debt. Socket roles own readiness/FINs.
pub const enabled = @import("build_options").relay_splice;
/// Owned and closed by linux_io.Io; never transferred to a connection slot.
pub const Pipe = struct {
    fds: [2]i32,
    capacity: usize,
};
pub const Pair = [2]Pipe;

/// A pump borrows an empty handle. Its defer drains pending bytes into its ring
/// (or discards fatal debt) before another callback can borrow the same pipe.
pub const Borrowed = struct {
    handle: Pipe,
    pending: usize = 0,
    read_paused: bool = false,
};
