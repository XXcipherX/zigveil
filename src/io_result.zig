//! Preserve Linux errno by value across the synchronous socket boundary.
pub const Errno = @import("std").os.linux.E;

pub fn Result(comptime T: type) type {
    return union(enum) { ok: T, err: Errno };
}

pub const Side = enum { client, backend };
pub const Operation = enum { read, write, shutdown, socket_error };
pub const Failure = union(enum) { errno: Errno, zero_write };
