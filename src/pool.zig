const std = @import("std");

/// Single-owner freelist. Each occupied slot has a distinct epoll generation.
pub const Pool = struct {
    const Entry = struct { next: ?u32, generation: u47 = 0, used: bool = false };
    entries: []Entry,
    free: ?u32,

    pub fn init(allocator: std.mem.Allocator, count: u32) !Pool {
        std.debug.assert(count != 0 and count <= 65536);
        const entries = try allocator.alloc(Entry, count);
        for (entries, 0..) |*entry, index| entry.* = .{ .next = if (index + 1 < count) @intCast(index + 1) else null };
        return .{ .entries = entries, .free = 0 };
    }

    pub fn deinit(self: *Pool, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
    }

    pub fn acquire(self: *Pool) ?u32 {
        const index = self.free orelse return null;
        const entry = &self.entries[index];
        self.free = entry.next;
        entry.used = true;
        // Retire at the ceiling on release, rather than wrapping a token.
        entry.generation += 1;
        return index;
    }

    pub fn release(self: *Pool, index: u32) void {
        const entry = &self.entries[index];
        std.debug.assert(entry.used);
        entry.used = false;
        if (entry.generation == std.math.maxInt(u47)) return;
        entry.next = self.free;
        self.free = index;
    }

    pub fn token(self: *const Pool, index: u32, backend: bool) u64 {
        return (@as(u64, self.entries[index].generation) << 17) | (@as(u64, index) << 1) | @intFromBool(backend);
    }

    pub fn resolve(self: *const Pool, value: u64) ?u32 {
        const index: u32 = @intCast((value >> 1) & 0xffff);
        if (index >= self.entries.len) return null;
        const entry = self.entries[index];
        if (!entry.used or value >> 17 != entry.generation) return null;
        return index;
    }
};

test "pool exhaustion and stale batch events after slot and fd reuse" {
    var pool = try Pool.init(std.testing.allocator, 1);
    defer pool.deinit(std.testing.allocator);
    const first = pool.acquire().?;
    const stale_client = pool.token(first, false);
    const stale_backend = pool.token(first, true);
    try std.testing.expect(pool.acquire() == null);
    try std.testing.expect(pool.resolve(stale_client) != null);
    pool.release(first);
    try std.testing.expect(pool.resolve(stale_backend) == null);
    const second = pool.acquire().?;
    try std.testing.expect(pool.resolve(stale_client) == null);
    try std.testing.expect(pool.resolve(pool.token(second, true)) != null);
    try std.testing.expect(pool.resolve(0) == null);
    try std.testing.expect(pool.resolve(1) == null);
    pool.release(second);
}
