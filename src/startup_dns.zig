//! Startup-only Linux lookup with bounded search names and one resolver snapshot.
const std = @import("std");
const Io = std.Io;
const net = Io.net;
const HostName = net.HostName;
const Results = Io.Queue(HostName.LookupResult);

pub fn lookup(name: HostName, io: Io, results: *Results, port: u16) !void {
    defer results.close(io);
    if (try lookupHosts(name, io, results, port)) return;
    const localhost = if (std.mem.endsWith(u8, name.bytes, ".")) "localhost." else "localhost";
    if (std.mem.endsWith(u8, name.bytes, localhost) and
        (name.bytes.len == localhost.len or name.bytes[name.bytes.len - localhost.len - 1] == '.'))
    {
        try results.putOne(io, .{ .address = .{ .ip6 = .loopback(port) } });
        try results.putOne(io, .{ .address = .{ .ip4 = .loopback(port) } });
        return;
    }

    const rc = HostName.ResolvConf.init(io) catch return error.ResolvConfParseFailed;
    // The std parser accepts zero; reject it before timeout division or DNS I/O.
    if (rc.attempts == 0) return error.InvalidDnsAttempts;
    const absolute = std.mem.endsWith(u8, name.bytes, ".");
    const bare = name.bytes[0 .. name.bytes.len - @intFromBool(absolute)];
    if (!absolute and std.mem.countScalar(u8, name.bytes, '.') < rc.ndots) {
        var buffer: [HostName.max_len]u8 = undefined;
        var suffixes = std.mem.tokenizeAny(u8, rc.search_buffer[0..rc.search_len], " \t");
        while (suffixes.next()) |suffix| {
            const candidate = searchName(&buffer, bare, suffix) orelse continue;
            lookupDns(candidate.bytes, io, &rc, results, port) catch |err| switch (err) {
                error.NoAddressReturned => continue,
                else => return err,
            };
            return;
        }
    }
    try lookupDns(bare, io, &rc, results, port);
}

fn searchName(buffer: *[HostName.max_len]u8, name: []const u8, suffix: []const u8) ?HostName {
    if (name.len >= buffer.len or suffix.len > buffer.len - name.len - 1) return null;
    @memcpy(buffer[0..name.len], name);
    buffer[name.len] = '.';
    @memcpy(buffer[name.len + 1 ..][0..suffix.len], suffix);
    return HostName.init(buffer[0 .. name.len + 1 + suffix.len]) catch null;
}

fn lookupHosts(name: HostName, io: Io, results: *Results, port: u16) !bool {
    const file = Io.Dir.openFileAbsolute(io, "/etc/hosts", .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.AccessDenied => return false,
        else => return err,
    };
    defer file.close(io);
    var storage: [512]u8 = undefined;
    var file_reader = file.reader(io, &storage);
    const reader = &file_reader.interface;
    var found = false;
    while (true) {
        const line = reader.takeDelimiterExclusive('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                _ = reader.discardDelimiterInclusive('\n') catch |discard_err| switch (discard_err) {
                    error.EndOfStream => break,
                    error.ReadFailed => return file_reader.err.?,
                };
                continue;
            },
            error.EndOfStream => break,
            error.ReadFailed => return file_reader.err.?,
        };
        reader.toss(@min(1, reader.bufferedLen()));
        var comments = std.mem.splitScalar(u8, line, '#');
        var fields = std.mem.tokenizeAny(u8, comments.first(), " \t");
        const ip = fields.next() orelse continue;
        while (fields.next()) |alias| {
            if (std.ascii.eqlIgnoreCase(alias, name.bytes)) break;
        } else continue;
        const address = net.IpAddress.parseIp4(ip, port) catch
            (net.IpAddress.parseIp6(ip, port) catch continue);
        try results.putOne(io, .{ .address = address });
        found = true;
    }
    return found;
}

fn query(buffer: *[280]u8, name_with_root: []const u8, record: HostName.DnsRecord, id: [2]u8) ![]const u8 {
    const name = try HostName.init(name_with_root);
    const bytes = name.bytes[0 .. name.bytes.len - @intFromBool(std.mem.endsWith(u8, name.bytes, "."))];
    @memset(buffer[0..12], 0);
    buffer[0..2].* = id;
    buffer[2] = 1;
    buffer[5] = 1;
    var position: usize = 12;
    var labels = std.mem.splitScalar(u8, bytes, '.');
    while (labels.next()) |label| {
        buffer[position] = @intCast(label.len);
        position += 1;
        @memcpy(buffer[position..][0..label.len], label);
        position += label.len;
    }
    buffer[position] = 0;
    std.mem.writeInt(u16, buffer[position + 1 ..][0..2], @backingInt(record), .big);
    std.mem.writeInt(u16, buffer[position + 3 ..][0..2], 1, .big);
    return buffer[0 .. position + 5];
}

fn lookupDns(name: []const u8, io: Io, rc: *const HostName.ResolvConf, results: *Results, port: u16) !void {
    var ids: [4]u8 = undefined;
    io.random(&ids);
    if (std.mem.eql(u8, ids[0..2], ids[2..4])) ids[3] ^= 1;
    var query_buffers: [2][280]u8 = undefined;
    const queries = [_][]const u8{
        try query(&query_buffers[0], name, .A, ids[0..2].*),
        try query(&query_buffers[1], name, .AAAA, ids[2..4].*),
    };
    var mapped_buffer: [HostName.ResolvConf.max_nameservers]net.IpAddress = undefined;
    const mapped = mapped_buffer[0..rc.nameservers_len];
    var any_ip6 = false;
    for (rc.nameservers(), mapped) |ns, *dest| {
        dest.* = .{ .ip6 = .fromAny(ns) };
        any_ip6 = any_ip6 or ns == .ip6;
    }
    const socket = bound: {
        if (any_ip6) ip6: {
            const address: net.IpAddress = .{ .ip6 = .unspecified(0) };
            const handle = address.bind(io, .{ .ip6_only = false, .mode = .dgram }) catch |err| switch (err) {
                error.AddressFamilyUnsupported => break :ip6,
                else => return err,
            };
            break :bound handle;
        }
        any_ip6 = false;
        const address: net.IpAddress = .{ .ip4 = .unspecified(0) };
        break :bound try address.bind(io, .{ .mode = .dgram });
    };
    defer socket.close(io);
    const nameservers = if (any_ip6) mapped else rc.nameservers();
    var answers: [2][]const u8 = .{ "", "" };
    var answer_storage: [2][1024]u8 = undefined;
    var receive_storage: [2048]u8 = undefined;
    var remaining: usize = answers.len;
    const clock: Io.Clock = .boot;
    var now = clock.now(io);
    const deadline = now.addDuration(.fromSeconds(rc.timeout_seconds));
    const attempt_duration: Io.Duration = .{
        .nanoseconds = (std.time.ns_per_s / rc.attempts) * @as(i96, rc.timeout_seconds),
    };
    send: while (now.nanoseconds < deadline.nanoseconds) : (now = clock.now(io)) {
        const timeout: Io.Timeout = .{ .deadline = .{ .raw = now.addDuration(attempt_duration), .clock = clock } };
        const max_messages = queries.len * HostName.ResolvConf.max_nameservers;
        var outgoing: [max_messages]net.OutgoingMessage = undefined;
        var count: usize = 0;
        for (queries, answers) |request, answer| {
            if (answer.len != 0) continue;
            for (nameservers) |*ns| {
                outgoing[count] = .{ .address = ns, .data_ptr = request.ptr, .data_len = request.len };
                count += 1;
            }
        }
        const send_err, _ = socket.sendManyTimeout(io, outgoing[0..count], .{}, timeout);
        if (send_err) |err| switch (err) {
            error.Canceled => return err,
            error.Timeout => continue :send,
            else => {},
        };
        while (true) {
            var incoming: [max_messages]net.IncomingMessage = @splat(.init);
            const recv_err, const received = socket.receiveManyTimeout(io, &incoming, &receive_storage, .{}, timeout);
            for (incoming[0..received]) |*message| {
                const reply = message.data;
                if (reply.len < 12 or reply.len > answer_storage[0].len or reply[2] & 0x80 == 0) continue;
                const ns = for (nameservers) |*ns| {
                    if (message.from.eql(ns)) break ns;
                } else continue;
                const index = for (queries, 0..) |request, index| {
                    if (std.mem.eql(u8, reply[0..2], request[0..2])) break index;
                } else continue;
                const request = queries[index];
                const answer = &answers[index];
                if (answer.len != 0) continue;
                switch (reply[3] & 15) {
                    0, 3 => {
                        @memcpy(answer_storage[index][0..reply.len], reply);
                        answer.* = answer_storage[index][0..reply.len];
                        remaining -= 1;
                        if (remaining == 0) break :send;
                    },
                    2 => socket.sendTimeout(io, ns, request, timeout) catch |err| switch (err) {
                        error.Canceled => return err,
                        error.Timeout => continue :send,
                        else => {},
                    },
                    else => {},
                }
            }
            if (recv_err) |err| switch (err) {
                error.Canceled => return err,
                error.Timeout => continue :send,
                else => continue,
            };
        }
    } else return error.NameServerFailure;

    var found = false;
    for (answers) |answer| {
        var response = HostName.DnsResponse.init(answer) catch continue;
        while (response.next() catch continue) |record| {
            const data = record.packet[record.data_off..][0..record.data_len];
            const address: net.IpAddress = switch (record.rr) {
                .A => if (data.len == 4) .{ .ip4 = .{ .bytes = data[0..4].*, .port = port } } else return error.InvalidDnsARecord,
                .AAAA => if (data.len == 16) .{ .ip6 = .{ .bytes = data[0..16].*, .port = port } } else return error.InvalidDnsAAAARecord,
                else => continue,
            };
            try results.putOne(io, .{ .address = address });
            found = true;
        }
    }
    if (!found) return error.NoAddressReturned;
}

test "search candidates stay inside DNS and storage limits" {
    var storage: [HostName.max_len]u8 = undefined;
    const label63: [63]u8 = @splat('a');
    const label30: [30]u8 = @splat('b');
    const label40: [40]u8 = @splat('c');
    const label61: [61]u8 = @splat('d');
    const label62: [62]u8 = @splat('e');
    const dot = [_]u8{'.'};
    const boundary = label63 ++ dot ++ label63 ++ dot ++ label63;
    const long_name = boundary ++ dot ++ label30;
    try std.testing.expect(searchName(&storage, &long_name, &label40) == null);
    const valid = searchName(&storage, &boundary, &label61).?;
    try std.testing.expectEqual(@as(usize, 253), valid.bytes.len);
    try std.testing.expect(searchName(&storage, &boundary, &label62) == null);
    try std.testing.expect(searchName(&storage, "backend", "bad..suffix") == null);
    const rooted_suffix = label61 ++ dot;
    const rooted = searchName(&storage, &boundary, &rooted_suffix).?;
    try std.testing.expectEqual(@as(usize, 254), rooted.bytes.len);
    var wire: [280]u8 = undefined;
    const encoded = try query(&wire, rooted.bytes, .A, .{ 0x12, 0x34 });
    try std.testing.expectEqual(@as(usize, 271), encoded.len);
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x34, 1, 0, 0, 1 }, encoded[0..6]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 0, 1 }, encoded[encoded.len - 4 ..]);
}
