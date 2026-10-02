const std = @import("std");

/// Fixed ring. Short sends advance the head; no compaction or growing queues.
pub const Buffer = struct {
    data: []u8,
    head: usize = 0,
    len: usize = 0,

    pub fn readable(self: *const Buffer) []const u8 {
        return self.data[self.head..][0..@min(self.len, self.data.len - self.head)];
    }

    pub fn writable(self: *Buffer) []u8 {
        const tail = (self.head + self.len) % self.data.len;
        return self.data[tail..][0..@min(self.data.len - self.len, self.data.len - tail)];
    }

    pub fn produced(self: *Buffer, count: usize) void {
        std.debug.assert(count <= self.data.len - self.len);
        self.len += count;
    }

    pub fn consumed(self: *Buffer, count: usize) void {
        std.debug.assert(count <= self.len);
        self.head = (self.head + count) % self.data.len;
        self.len -= count;
    }
};

test "partial consumption, wrap and bounded backpressure" {
    var bytes: [8]u8 = undefined;
    var queue: Buffer = .{ .data = &bytes };
    @memcpy(queue.writable()[0..6], "abcdef");
    queue.produced(6);
    queue.consumed(5);
    @memcpy(queue.writable(), "gh");
    queue.produced(2);
    @memcpy(queue.writable()[0..5], "ijklm");
    queue.produced(5);
    try std.testing.expectEqual(@as(usize, 0), queue.writable().len);
    try std.testing.expectEqualStrings("fgh", queue.readable());
    queue.consumed(3);
    try std.testing.expectEqualStrings("ijklm", queue.readable());
}
