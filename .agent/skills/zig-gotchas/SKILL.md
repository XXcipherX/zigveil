---
name: zigveil-zig-gotchas
description: Zig 0.17.0 API and Linux syscall details relevant to this project's dataplane.
---

# Zig and Linux pitfalls

## Versioned API anchors

- `std.process.Init.Minimal`: argv/env without automatic std.Io.Threaded startup.
- `init.args.toSlice(allocator)`: startup-owned argument slices.
- `std.Io.net.IpAddress.parseLiteral`: IPv4 `IP:port`, IPv6 `[IP]:port`.
- `startup_dns.lookup`: project-owned bounded lookup using Zig networking/DNS types;
  join its future before releasing buffers. Drain the bounded queue while it produces.
- `std.os.linux`: raw errno-encoded syscall results; always call `linux.errno(rc)`.
- `std.Build.createModule` plus `addExecutable(.{ .root_module = ... })`.
- `std.json.parseFromSlice`: reject unknown fields; retain parsed owner through serving.

Check the installed 0.17.0 standard library or the tagged official source before
using a new API. ArrayList and std.Io APIs differ from older Zig releases.
Use `std.lang.Optimize` and the canonical `debug/safe/fast/small` names. The build
requires the exact stable release; prerelease/build suffixes are rejected.
Reflection uses `field_names`/`field_types`/`field_attrs`, with parallel iteration
when names and types are both needed. Use `@splat` for repeated arrays,
`@backingInt`/`@fromBackingInt` for enum backing values, `std.mem.print` for fixed
format buffers, `std.mem.find`/`findScalar` for search and `@memmove` for overlap.
`@fromBackingInt` needs the exact backing integer type.
The startup resolver uses one explicit concurrent worker and destroys its
`std.Io.Threaded` instance before Server.init. Do not set the executable's
single_threaded compile option or move resolver operations into the relay.
Keep composed search names within HostName/DNS bounds before slicing. Pass the
same resolver snapshot to search and transport; a separate preflight followed by
an unchecked std lookup would read a second, potentially changed configuration.

## Integer and slice safety

Attacker lengths widen before arithmetic. Check `remaining >= n` before subtracting
or slicing. A TLS record's u16 payload length is not a staging total. Total wire cap
includes each record header. Handshake u24 lengths cannot dictate allocation.
Do not rely on debug assertions for untrusted input validation: fast removes
safety checks. Keep all attacker checks as ordinary branches.

For narrow integers, `value << 8` may itself be invalid; accumulate in a wider type
before narrowing. Ring offsets/counts stay inside the reserved slice. Avoid
returning slices into stack temporaries or by-value copied structs: owned `Name`
is accessed via a live pointer, and connection slices reference stable server slabs.

## Linux details

Raw sockaddr ports are network byte order; IPv4 bytes must preserve their memory
layout. IPv6 flow/scope are zero because scoped literals are unsupported.
getpeername/getsockname take `*sockaddr` and `*socklen_t`; initialize storage/length
for each attempt, retry EINTR, validate returned family/length before casting.
PROXY v2 uses the accepted socket's peer and local endpoint, including actual
wildcard destination. Native sockaddr storage is aligned; preserve IPv4 memory
bytes with toBytes when decoding. Never substitute the configured backend address.
Zig 0.17 `@bitCast` uses logical bits, independent of byte order. Use
`std.mem.bytesToValue` for IPv4 sockaddr memory bytes, not an array-to-integer cast.
The remaining signed/unsigned scalar bitcasts only encode negative syscall errno
in test fixtures. Audit generated code as well as semantics after compiler changes.
Socket creation and accept4 include NONBLOCK and CLOEXEC atomically.
EINTR retries I/O, not Linux close. MSG_NOSIGNAL makes EPIPE an ordinary error.
Splice has no MSG_NOSIGNAL flag: Server scopes SIGPIPE ignore/restore while the
shared path is enabled. Use nonblocking pipe/socket ends and null splice offsets.
A pipe can exhaust page slots before its byte capacity; source EAGAIN with debt
pauses reads until a successful write. Reclaim all pending bytes before returning
to epoll, including fatal/yield exits; teardown never closes borrowed handles.
Nonblocking connect success is checked with SO_ERROR only after that fd is ready.
recv/send/shutdown/SO_ERROR carry `Result(T)` with the exact non-exhaustive Linux.E,
not generic errors or a shared mutable errno slot. SO_ERROR's returned integer is
a positive errno, unlike the negative raw syscall result. Reading SO_ERROR clears
it; do not add probes merely to collect diagnostics on successful I/O.

Runtime logging uses the single-owner Logger, not std.log's global settings or
stderr mutex. Keep raw counters separate from log interval baselines, with wrapping
differences for events and unchanged gauges. Validate none/error/warn/info/debug
and text/json before any startup resolution. Keep SIGUSR2 in the signalfd mask;
explicit snapshots and --check bypass automatic verbosity. Escape message control
bytes and preserve fixed-buffer worst-case bounds, including max-u64 byte units.

Linux accept4 may return pending per-connection network errors. Continue only
within the accept budget; back off for fd/memory pressure and propagate fatal
listener/policy failures. EAGAIN and EINTR do not increment accept_errors.
EINTR consumes an accept attempt instead of hiding an unlimited retry loop.

Shutdown ENOTCONN is distinct from EPIPE/ECONNRESET. After debt drains, the engine
probes SO_ERROR before completing the disconnected half; do not suppress pending
reset errors or finish a write half while its prefix/ring/pipe remains queued.

Mask zero is not a reliable way to suppress HUP: remove a socket with no useful
interest. Watch OUT only when there is debt. IN/RDHUP stops after real read EOF or
full queues, and is restored when destination writes free room. Cached events can
remain after DEL/close, so the token generation check is mandatory.

## Testing traps

Never return a Rig/fixture by value after wiring slices into its own arrays.
Initialize it in place. Fakes must return actual partial counts and typed EAGAIN,
not silently complete writes. A test must detect lost/duplicated bytes, FIN ordering,
deadlock, or lifetime misuse rather than merely mirror an implementation branch.
Run meaningful security checks with safety enabled and validate the production
fast path separately. Keep benchmark-generated numbers out of documentation
until recorded with a reproducible methodology.
