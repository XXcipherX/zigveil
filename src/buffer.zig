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
        self.len -= count;
        // An empty queue has no borrowed data. Reuse its full contiguous span
        // rather than splitting the next read at the previous short-send head.
        self.head = if (self.len == 0) 0 else (self.head + count) % self.data.len;
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

test "a drained short or wrapped queue restores a full writable span" {
    var bytes: [7]u8 = undefined;
    var queue: Buffer = .{ .data = &bytes };
    @memcpy(queue.writable()[0..3], "abc");
    queue.produced(3);
    queue.consumed(3);
    try std.testing.expectEqual(@as(usize, 7), queue.writable().len);
    @memcpy(queue.writable()[0..6], "defghi");
    queue.produced(6);
    queue.consumed(5);
    @memcpy(queue.writable(), "j");
    queue.produced(1);
    @memcpy(queue.writable()[0..3], "klm");
    queue.produced(3);
    try std.testing.expectEqualStrings("ij", queue.readable());
    queue.consumed(2);
    try std.testing.expectEqualStrings("klm", queue.readable());
    queue.consumed(3);
    try std.testing.expectEqual(@as(usize, 0), queue.head);
    try std.testing.expectEqual(@as(usize, 7), queue.writable().len);
}
