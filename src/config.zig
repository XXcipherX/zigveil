const std = @import("std");
const Name = @import("name.zig").Name;
const backend_mod = @import("backend.zig");
const logging = @import("log.zig");
pub const Address = std.Io.net.IpAddress;
pub const hello_bytes = @import("client_hello.zig").max_wire_bytes;

pub const Raw = struct {
    listen: []const u8,
    routes: []const struct { sni: []const u8, backend: []const u8 },
    fallback: ?[]const u8 = null,
    max_connections: u32 = 1024,
    max_handshakes: u32 = 64,
    relay_buffer_bytes: u32 = 65536,
    hello_timeout_ms: u32 = 5000,
    connect_timeout_ms: u32 = 5000,
    idle_timeout_ms: u32 = 300000,
    stats_interval_ms: u32 = 30000,
    log_level: logging.Level = .info,
    log_format: logging.Format = .text,
    reuse_port: bool = false,
};

pub const Route = struct { name: Name, backend: Address };
pub const Config = struct {
    raw: std.json.Parsed(Raw),
    listen: Address,
    routes: []Route,
    fallback: ?Address,

    pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !Config {
        var resolver: backend_mod.Resolver = .{};
        defer resolver.deinit();
        return parseWithResolver(allocator, bytes, &resolver);
    }

    /// The resolver seam is startup-only; tests can provide deterministic DNS.
    pub fn parseWithResolver(allocator: std.mem.Allocator, bytes: []const u8, resolver: anytype) !Config {
        const parsed = try std.json.parseFromSlice(Raw, allocator, bytes, .{});
        errdefer parsed.deinit();
        const raw = parsed.value;
        if (raw.max_connections == 0 or raw.max_connections > 65536) return error.MaxConnectionsOutOfRange;
        if (raw.max_handshakes == 0 or raw.max_handshakes > raw.max_connections) return error.MaxHandshakesOutOfRange;
        const n = raw.relay_buffer_bytes;
        if (n < 4096 or n > 65536 or n & (n - 1) != 0) return error.RelayBufferMustBePowerOfTwoBetween4And64KiB;
        if (raw.hello_timeout_ms < 250 or raw.hello_timeout_ms > 60000) return error.HelloTimeoutMustBe250To60000Ms;
        if (raw.connect_timeout_ms < 250 or raw.connect_timeout_ms > 60000) return error.ConnectTimeoutMustBe250To60000Ms;
        if (raw.idle_timeout_ms != 0 and raw.idle_timeout_ms < 250) return error.IdleTimeoutMustBeZeroOrAtLeast250Ms;
        if (raw.stats_interval_ms != 0 and raw.stats_interval_ms < 1000) return error.StatsIntervalMustBeZeroOrAtLeast1000Ms;
        if (raw.routes.len > 1024 or (raw.routes.len == 0 and raw.fallback == null)) return error.NeedOneTo1024RoutesOrFallback;
        if (bufferBytes(raw) > 1024 * 1024 * 1024) return error.BufferReservationExceeds1GiB;
        const listen = address(raw.listen) catch return error.InvalidListenAddress;
        const fallback_endpoint = if (raw.fallback) |text| try backend_mod.Endpoint.parse(text) else null;
        if (fallback_endpoint) |endpoint| if (endpoint == .address) try validateTarget(listen, endpoint.address);
        const routes = try allocator.alloc(Route, raw.routes.len);
        errdefer allocator.free(routes);
        for (raw.routes, 0..) |route, i| {
            const endpoint = try backend_mod.Endpoint.parse(route.backend);
            routes[i] = .{ .name = Name.parse(route.sni) catch return error.InvalidRouteHostname, .backend = undefined };
            for (routes[0..i]) |previous| if (previous.name.eql(&routes[i].name)) return error.DuplicateRoute;
            if (endpoint == .address) try validateTarget(listen, endpoint.address);
        }
        // Validate every name/endpoint before doing any hostname lookup.
        for (raw.routes, routes) |route, *dest| {
            const endpoint = try backend_mod.Endpoint.parse(route.backend);
            dest.backend = try endpoint.resolve(resolver);
            try validateTarget(listen, dest.backend);
        }
        const fallback = if (fallback_endpoint) |endpoint| try endpoint.resolve(resolver) else null;
        if (fallback) |dest| try validateTarget(listen, dest);
        return .{ .raw = parsed, .listen = listen, .routes = routes, .fallback = fallback };
    }

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.routes);
        self.raw.deinit();
    }

    pub fn lookup(self: *const Config, name: ?*const Name) ?Address {
        if (name) |value| for (self.routes) |route| {
            if (route.name.eql(value)) return route.backend;
        };
        return null;
    }

    pub fn bufferBytes(raw: Raw) u64 {
        return @as(u64, raw.max_connections) * 2 * raw.relay_buffer_bytes + @as(u64, raw.max_handshakes) * hello_bytes;
    }
};

fn address(text: []const u8) !Address {
    const addr = try Address.parseLiteral(text);
    const port = switch (addr) {
        .ip4 => |a| a.port,
        .ip6 => |a| a.port,
    };
    if (port == 0) return error.PortRequired;
    return addr;
}

fn validateTarget(listen: Address, addr: Address) !void {
    switch (effectiveBackend(addr)) {
        .ip4 => |a| if (std.mem.allEqual(u8, &a.bytes, 0) or a.bytes[0] >= 224) return error.BackendMustBeUnicast,
        .ip6 => |a| if (std.mem.allEqual(u8, &a.bytes, 0) or a.bytes[0] == 0xff) return error.BackendMustBeUnicast,
    }
    if (backendTargetsListener(listen, addr)) return error.BackendEqualsListener;
}

// Mapped backend destinations use IPv4 routing; keep their configured form for I/O.
fn effectiveBackend(addr: Address) Address {
    return switch (addr) {
        .ip4 => addr,
        .ip6 => |a| Address.fromIp6(a),
    };
}

fn backendTargetsListener(listen: Address, backend: Address) bool {
    if (listen.getPort() != backend.getPort()) return false;
    if (std.meta.eql(listen, backend)) return true;
    const dest = effectiveBackend(backend);
    if (std.meta.eql(listen, dest)) return true;
    // Only syntactically certain local targets; no interface/routing discovery.
    // IPv6 listeners are V6ONLY, so IPv4/mapped destinations are independent.
    return switch (listen) {
        .ip4 => |bound| switch (dest) {
            .ip4 => |a| std.mem.allEqual(u8, &bound.bytes, 0) and a.bytes[0] == 127,
            .ip6 => false,
        },
        .ip6 => |bound| switch (dest) {
            .ip4 => false,
            .ip6 => |a| std.mem.allEqual(u8, &bound.bytes, 0) and std.mem.allEqual(u8, a.bytes[0..15], 0) and a.bytes[15] == 1,
        },
    };
}

test "exact canonical routes, missing and unknown names, fallback" {
    var config = try Config.parse(std.testing.allocator,
        \\{"listen":"127.0.0.1:8443","routes":[{"sni":"EXAMPLE.com","backend":"127.0.0.1:9443"}],"fallback":"[::1]:9444"}
    );
    defer config.deinit(std.testing.allocator);
    const known = try Name.parse("eXAMPLE.com");
    const unknown = try Name.parse("example.org");
    try std.testing.expect(config.lookup(&known) != null);
    try std.testing.expect(config.lookup(&unknown) == null);
    try std.testing.expect(config.lookup(null) == null);
    try std.testing.expect(config.fallback != null);
    try std.testing.expectEqual(@as(u64, 132 * 1024 * 1024), Config.bufferBytes(config.raw.value));
}

test "reject unknown keys, duplicate routes, invalid endpoints and resource limits" {
    const inputs = [_][]const u8{
        \\{"listen":"0.0.0.0:443","routes":[],"fallback":"https://example.com:443"}
        ,
        \\{"listen":"0.0.0.0:443","routes":[],"fallback":"127.0.0.1:443","max_connections":0}
        ,
        \\{"listen":"0.0.0.0:443","routes":[],"fallback":"127.0.0.1:443","relay_buffer_bytes":6000}
        ,
        \\{"listen":"0.0.0.0:443","routes":[],"fallback":"127.0.0.1:443","typo":1}
        ,
        \\{"listen":"0.0.0.0:443","routes":[{"sni":"a.net","backend":"127.0.0.1:9443"},{"sni":"A.NET","backend":"127.0.0.2:9443"}]}
        ,
    };
    for (inputs) |input| {
        if (Config.parse(std.testing.allocator, input)) |value| {
            var unexpected = value;
            unexpected.deinit(std.testing.allocator);
            return error.ExpectedConfigRejection;
        } else |_| {}
    }
}

fn checkEndpointConfig(listen: []const u8, backend: []const u8, fallback: bool, rejection: ?anyerror) !void {
    var storage: [512]u8 = undefined;
    const json = if (fallback)
        try std.fmt.bufPrint(&storage, "{{\"listen\":\"{s}\",\"routes\":[],\"fallback\":\"{s}\"}}", .{ listen, backend })
    else
        try std.fmt.bufPrint(&storage, "{{\"listen\":\"{s}\",\"routes\":[{{\"sni\":\"example.com\",\"backend\":\"{s}\"}}]}}", .{ listen, backend });
    if (Config.parse(std.testing.allocator, json)) |value| {
        var config = value;
        defer config.deinit(std.testing.allocator);
        try std.testing.expect(rejection == null);
    } else |err| {
        try std.testing.expectEqual(rejection orelse return err, err);
    }
}

test "routes and fallback reject exact and wildcard-loopback self targets" {
    const cases = [_][2][]const u8{
        .{ "127.0.0.1:443", "127.0.0.1:443" },
        .{ "[::1]:443", "[0:0:0:0:0:0:0:1]:443" },
        .{ "0.0.0.0:443", "127.0.0.1:443" },
        .{ "0.0.0.0:443", "127.0.0.2:443" },
        .{ "0.0.0.0:443", "127.42.0.8:443" },
        .{ "[::]:443", "[::1]:443" },
        .{ "0.0.0.0:443", "[::ffff:127.0.0.1]:443" },
        .{ "127.0.0.1:443", "[::ffff:127.0.0.1]:443" },
    };
    for (cases) |case| for ([_]bool{ false, true }) |fallback| {
        try checkEndpointConfig(case[0], case[1], fallback, error.BackendEqualsListener);
    };
}

test "self target validation preserves other ports, remote peers and V6ONLY independence" {
    const cases = [_][2][]const u8{
        .{ "127.0.0.1:443", "127.0.0.1:9443" },
        .{ "[::1]:443", "[::1]:9443" },
        .{ "0.0.0.0:443", "127.0.0.1:9443" },
        .{ "[::]:443", "[::1]:9443" },
        .{ "0.0.0.0:443", "203.0.113.10:443" },
        .{ "[::]:443", "[2001:db8::10]:443" },
        .{ "127.0.0.1:443", "127.0.0.2:443" },
        .{ "[::]:443", "127.0.0.1:443" },
        .{ "[::]:443", "[::ffff:127.0.0.1]:443" },
        .{ "0.0.0.0:443", "[::1]:443" },
        .{ "0.0.0.0:443", "[::ffff:203.0.113.10]:443" },
    };
    for (cases) |case| for ([_]bool{ false, true }) |fallback| {
        try checkEndpointConfig(case[0], case[1], fallback, null);
    };
}

test "unspecified and mapped non-unicast backends remain invalid for routes and fallback" {
    for ([_][]const u8{ "0.0.0.0:9443", "[::]:9443", "[::ffff:0.0.0.0]:9443", "[::ffff:224.0.0.1]:9443" }) |backend| {
        for ([_]bool{ false, true }) |fallback| {
            try checkEndpointConfig("0.0.0.0:443", backend, fallback, error.BackendMustBeUnicast);
        }
    }
}

const TestResolver = struct {
    calls: usize = 0,
    target: Address,
    failure: ?anyerror = null,

    pub fn resolve(self: *TestResolver, _: std.Io.net.HostName, port: u16) !Address {
        self.calls += 1;
        if (self.failure) |err| return err;
        var addr = self.target;
        switch (addr) {
            .ip4 => |*a| a.port = port,
            .ip6 => |*a| a.port = port,
        }
        return addr;
    }
};

test "host routes and fallback resolve at startup and retain only numeric endpoints" {
    var resolver: TestResolver = .{ .target = try Address.parseLiteral("203.0.113.10:1") };
    var config = try Config.parseWithResolver(std.testing.allocator,
        \\{"listen":"0.0.0.0:443","routes":[{"sni":"example.com","backend":"backend.example.com:9443"}],"fallback":"fallback.example.com:9444"}
    , &resolver);
    defer config.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), resolver.calls);
    const name = try Name.parse("example.com");
    for (0..10) |_| try std.testing.expectEqual(@as(u16, 9443), config.lookup(&name).?.getPort());
    try std.testing.expectEqual(@as(u16, 9444), config.fallback.?.getPort());
    try std.testing.expectEqual(@as(usize, 2), resolver.calls);
}

test "numeric endpoints and invalid complete configs do not invoke a resolver" {
    var resolver: TestResolver = .{ .target = try Address.parseLiteral("203.0.113.10:1") };
    var numeric = try Config.parseWithResolver(std.testing.allocator,
        \\{"listen":"0.0.0.0:443","routes":[{"sni":"example.com","backend":"203.0.113.10:443"}]}
    , &resolver);
    numeric.deinit(std.testing.allocator);
    const cases = [_][]const u8{
        \\{"listen":"0.0.0.0:443","routes":[{"sni":"example.com","backend":"backend.example.com:443"},{"sni":"example.org","backend":"https://example.org:443"}]}
        ,
        \\{"listen":"0.0.0.0:443","routes":[{"sni":"example.com","backend":"backend.example.com:443"},{"sni":"EXAMPLE.COM","backend":"other.example.com:443"}]}
        ,
        \\{"listen":"example.com:443","routes":[],"fallback":"backend.example.com:443"}
        ,
    };
    for (cases) |input| {
        if (Config.parseWithResolver(std.testing.allocator, input, &resolver)) |value| {
            var unexpected = value;
            unexpected.deinit(std.testing.allocator);
            return error.ExpectedConfigRejection;
        } else |_| {}
    }
    try std.testing.expectEqual(@as(usize, 0), resolver.calls);
}

test "resolved self targets and non-unicast targets fail for routes and fallback" {
    for ([_][]const u8{ "127.0.0.1:1", "[::ffff:127.0.0.1]:1", "[::1]:1", "0.0.0.0:1", "[::]:1", "224.0.0.1:1" }) |target| for ([_]bool{ false, true }) |fallback| {
        var resolver: TestResolver = .{ .target = try Address.parseLiteral(target) };
        var storage: [512]u8 = undefined;
        const listen = if (std.mem.startsWith(u8, target, "[::1]")) "[::]:443" else "0.0.0.0:443";
        const input = if (fallback)
            try std.fmt.bufPrint(&storage, "{{\"listen\":\"{s}\",\"routes\":[],\"fallback\":\"backend.example.com:443\"}}", .{listen})
        else
            try std.fmt.bufPrint(&storage, "{{\"listen\":\"{s}\",\"routes\":[{{\"sni\":\"example.com\",\"backend\":\"backend.example.com:443\"}}]}}", .{listen});
        if (Config.parseWithResolver(std.testing.allocator, input, &resolver)) |value| {
            var unexpected = value;
            unexpected.deinit(std.testing.allocator);
            return error.ExpectedConfigRejection;
        } else |err| {
            const expected: anyerror = if (std.mem.eql(u8, target, "0.0.0.0:1") or std.mem.eql(u8, target, "[::]:1") or std.mem.eql(u8, target, "224.0.0.1:1")) error.BackendMustBeUnicast else error.BackendEqualsListener;
            try std.testing.expectEqual(expected, err);
        }
        try std.testing.expectEqual(@as(usize, 1), resolver.calls);
    };
}

test "DNS failure propagates and resolved IPv6 and alternate ports stay valid" {
    const input =
        \\{"listen":"0.0.0.0:443","routes":[],"fallback":"backend.example.com:9443"}
    ;
    var failed: TestResolver = .{ .target = try Address.parseLiteral("203.0.113.10:1"), .failure = error.UnknownHostName };
    try std.testing.expectError(error.UnknownHostName, Config.parseWithResolver(std.testing.allocator, input, &failed));
    for ([_][]const u8{ "127.0.0.1:1", "[::1]:1", "[2001:db8::10]:1" }) |target| {
        var resolver: TestResolver = .{ .target = try Address.parseLiteral(target) };
        var config = try Config.parseWithResolver(std.testing.allocator, input, &resolver);
        defer config.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u16, 9443), config.fallback.?.getPort());
    }
}
