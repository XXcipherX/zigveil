//! Fixed-capacity indexed min-heap: at most one timer for each connection slot.
const std = @import("std");
pub const Node = struct { when: u64, slot: u32 };
const absent = std.math.maxInt(u32);

pub const Timers = struct {
    nodes: []Node,
    positions: []u32,
    len: usize = 0,

    pub fn init(allocator: std.mem.Allocator, capacity: u32) !Timers {
        const nodes = try allocator.alloc(Node, capacity);
        errdefer allocator.free(nodes);
        const positions = try allocator.alloc(u32, capacity);
        @memset(positions, absent);
        return .{ .nodes = nodes, .positions = positions };
    }

    pub fn deinit(self: *Timers, allocator: std.mem.Allocator) void {
        allocator.free(self.positions);
        allocator.free(self.nodes);
    }

    pub fn first(self: *const Timers) ?Node {
        return if (self.len == 0) null else self.nodes[0];
    }

    pub fn set(self: *Timers, slot: u32, when: ?u64) void {
        const position = self.positions[slot];
        if (when) |deadline| {
            if (position != absent) {
                self.nodes[position].when = deadline;
                self.fix(position);
            } else {
                const at = self.len;
                self.len += 1;
                self.nodes[at] = .{ .slot = slot, .when = deadline };
                self.positions[slot] = @intCast(at);
                self.up(at);
            }
        } else if (position != absent) {
            self.positions[slot] = absent;
            self.len -= 1;
            if (position == self.len) return;
            self.nodes[position] = self.nodes[self.len];
            self.positions[self.nodes[position].slot] = position;
            self.fix(position);
        }
    }

    fn less(a: Node, b: Node) bool {
        return a.when < b.when or (a.when == b.when and a.slot < b.slot);
    }

    fn swap(self: *Timers, a: usize, b: usize) void {
        std.mem.swap(Node, &self.nodes[a], &self.nodes[b]);
        self.positions[self.nodes[a].slot] = @intCast(a);
        self.positions[self.nodes[b].slot] = @intCast(b);
    }

    fn up(self: *Timers, position: usize) void {
        var at = position;
        while (at != 0) {
            const parent = (at - 1) / 2;
            if (!less(self.nodes[at], self.nodes[parent])) break;
            self.swap(at, parent);
            at = parent;
        }
    }

    fn fix(self: *Timers, position: usize) void {
        if (position != 0 and less(self.nodes[position], self.nodes[(position - 1) / 2])) {
            self.up(position);
            return;
        }
        var at = position;
        while (at * 2 + 1 < self.len) {
            var child = at * 2 + 1;
            if (child + 1 < self.len and less(self.nodes[child + 1], self.nodes[child])) child += 1;
            if (!less(self.nodes[child], self.nodes[at])) break;
            self.swap(at, child);
            at = child;
        }
    }
};

test "timer update, cancellation, equal deadlines and slot reuse" {
    var timers = try Timers.init(std.testing.allocator, 4);
    defer timers.deinit(std.testing.allocator);
    timers.set(0, 50);
    timers.set(1, 20);
    timers.set(2, 30);
    timers.set(3, 10);
    try std.testing.expectEqual(@as(u32, 3), timers.first().?.slot);
    timers.set(3, 100);
    timers.set(2, 5);
    try std.testing.expectEqual(@as(u32, 2), timers.first().?.slot);
    timers.set(2, null);
    timers.set(1, null);
    timers.set(1, 50);
    try std.testing.expectEqual(@as(u32, 0), timers.first().?.slot);
    timers.set(0, null);
    try std.testing.expectEqual(@as(u32, 1), timers.first().?.slot);
    timers.set(1, null);
    timers.set(3, null);
    timers.set(3, null);
    try std.testing.expect(timers.first() == null);
}

test "indexed timers match an independent linear model under mixed operations" {
    var timers = try Timers.init(std.testing.allocator, 32);
    defer timers.deinit(std.testing.allocator);
    var model: [32]?u64 = @splat(null);
    var generator = std.Random.DefaultPrng.init(0x74696d657273);
    const random = generator.random();
    for (0..6000) |_| {
        const slot = random.uintLessThan(u32, model.len);
        const value: ?u64 = if (random.boolean()) random.uintLessThan(u64, 1000) else null;
        model[slot] = value;
        timers.set(slot, value);
        var expected: ?Node = null;
        var count: usize = 0;
        for (model, 0..) |deadline, index| if (deadline) |when| {
            count += 1;
            const candidate: Node = .{ .when = when, .slot = @intCast(index) };
            if (expected == null or candidate.when < expected.?.when or
                (candidate.when == expected.?.when and candidate.slot < expected.?.slot)) expected = candidate;
        };
        try std.testing.expectEqual(count, timers.len);
        try std.testing.expectEqual(expected, timers.first());
    }
}
