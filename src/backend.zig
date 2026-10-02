//! Startup-only endpoint parsing and hostname resolution. Relay uses numeric IPs.
const std = @import("std");
const Address = std.Io.net.IpAddress;
const HostName = std.Io.net.HostName;

pub const Endpoint = union(enum) {
    address: Address,
    host: struct { name: HostName, port: u16 },

    pub fn parse(text: []const u8) !Endpoint {
        if (Address.parseLiteral(text)) |addr| {
            if (addr.getPort() == 0) return error.InvalidBackendAddress;
            return .{ .address = addr };
        } else |_| {}

        const colon = std.mem.indexOfScalar(u8, text, ':') orelse return error.InvalidBackendAddress;
        const host = text[0..colon];
        const port_text = text[colon + 1 ..];
        if (host.len == 0 or port_text.len == 0) return error.InvalidBackendAddress;
        for (port_text) |c| if (!std.ascii.isDigit(c)) return error.InvalidBackendAddress;
        const port = std.fmt.parseInt(u16, port_text, 10) catch return error.InvalidBackendAddress;
        if (port == 0) return error.InvalidBackendAddress;
        // Do not turn malformed numeric addresses into DNS search queries.
        if (std.mem.findNone(u8, host, "0123456789.") == null) return error.InvalidBackendAddress;
        const length = host.len - @intFromBool(host[host.len - 1] == '.');
        if (length > 253) return error.InvalidBackendAddress;
        const name = HostName.init(host) catch return error.InvalidBackendAddress;
        return .{ .host = .{ .name = name, .port = port } };
    }

    pub fn resolve(self: Endpoint, resolver: anytype) !Address {
        return switch (self) {
            .address => |addr| addr,
            .host => |host| try resolver.resolve(host.name, host.port),
        };
    }
};

const Selection = struct {
    ip4: ?Address = null,
    ip6: ?Address = null,

    fn add(self: *Selection, address: Address) void {
        const effective = switch (address) {
            .ip4 => address,
            .ip6 => |ip6| Address.fromIp6(ip6),
        };
        switch (effective) {
            .ip4 => if (self.ip4 == null) {
                self.ip4 = address;
            },
            .ip6 => if (self.ip6 == null) {
                self.ip6 = address;
            },
        }
    }

    fn result(self: Selection) !Address {
        return self.ip4 orelse self.ip6 orelse return error.NoAddressReturned;
    }
};

pub const Resolver = struct {
    threaded: ?std.Io.Threaded = null,

    pub fn deinit(self: *Resolver) void {
        if (self.threaded) |*threaded| threaded.deinit();
        self.threaded = null;
    }

    pub fn resolve(self: *Resolver, host: HostName, port: u16) !Address {
        // Lazy initialization leaves numeric-only startup unchanged. One worker
        // lets the caller drain bounded results even for large /etc/hosts lists.
        if (self.threaded == null) self.threaded = std.Io.Threaded.init(std.heap.page_allocator, .{
            .async_limit = .nothing,
            .concurrent_limit = .limited(1),
        });
        const io = self.threaded.?.io();
        var name_buffer: [254]u8 = undefined;
        for (host.bytes, name_buffer[0..host.bytes.len]) |c, *dest| dest.* = std.ascii.toLower(c);
        const name: HostName = .{ .bytes = name_buffer[0..host.bytes.len] };
        var results_buffer: [16]HostName.LookupResult = undefined;
        var results: std.Io.Queue(HostName.LookupResult) = .init(&results_buffer);
        var lookup = try io.concurrent(HostName.lookup, .{ name, io, &results, HostName.LookupOptions{ .port = port } });
        defer lookup.cancel(io) catch {};
        var selection: Selection = .{};
        while (results.getOne(io)) |result| {
            switch (result) {
                .address => |addr| selection.add(addr),
                .canonical_name => {},
            }
        } else |err| switch (err) {
            error.Closed => {},
            else => return err,
        }
        try lookup.await(io);
        return selection.result();
    }
};

test "backend literals and hostnames require a port and reject URLs" {
    const ip4 = try Endpoint.parse("203.0.113.10:443");
    try std.testing.expectEqual(@as(u16, 443), ip4.address.getPort());
    const ip6 = try Endpoint.parse("[2001:db8::10]:9443");
    try std.testing.expectEqual(@as(u16, 9443), ip6.address.getPort());
    for ([_][]const u8{ "example.com:443", "Example.COM:9443", "localhost:443", "example.com.:443", "xn--e1afmkfd.example:65535" }) |text| {
        const endpoint = try Endpoint.parse(text);
        try std.testing.expect(endpoint.host.port != 0);
    }
    for ([_][]const u8{ "", "example.com", "example.com:", "example.com:0", "example.com:65536", "example.com:+443", "example.com:443/", "https://example.com:443", "tcp://example.com:443", "user@example.com:443", "bad_name.example:443", " example.com:443", ".example.com:443", "example..com:443", "пример.example:443", "127.0.0.999:443", "127.0.0.1:0", "[::1]:0", "::1:443", "[example.com]:443" }) |text| {
        try std.testing.expectError(error.InvalidBackendAddress, Endpoint.parse(text));
    }
    try std.testing.expectError(error.InvalidBackendAddress, Endpoint.parse("a" ** 64 ++ ".example:443"));
    try std.testing.expectError(error.InvalidBackendAddress, Endpoint.parse("a." ** 127 ++ "a:443"));
}

test "resolved selection prefers the first IPv4 otherwise the first IPv6" {
    var selection: Selection = .{};
    try std.testing.expectError(error.NoAddressReturned, selection.result());
    const first6 = try Address.parseLiteral("[2001:db8::10]:443");
    selection.add(first6);
    selection.add(try Address.parseLiteral("[2001:db8::20]:443"));
    try std.testing.expect(std.meta.eql(first6, try selection.result()));
    const first4 = try Address.parseLiteral("203.0.113.10:443");
    selection.add(first4);
    selection.add(try Address.parseLiteral("203.0.113.20:443"));
    try std.testing.expect(std.meta.eql(first4, try selection.result()));
    var mapped: Selection = .{};
    mapped.add(first6);
    const alias = try Address.parseLiteral("[::ffff:203.0.113.10]:443");
    mapped.add(alias);
    try std.testing.expect(std.meta.eql(alias, try mapped.result()));
}
