//! Optional kernel queue ownership. Socket roles still own readiness and FINs.
pub const enabled = @import("build_options").relay_splice;
pub const Pipe = struct {
    fds: [2]i32,
    capacity: usize,
    pending: usize = 0,
    read_paused: bool = false,
};
pub const Pair = [2]Pipe;
