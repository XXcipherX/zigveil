# Architecture and decisions

## Workload and cost model

Zigveil forwards long-lived opaque TCP streams. Routing happens once; bulk copying,
kernel TCP work, syscall cost and queue scheduling dominate sustained traffic.
The proxy preserves the complete TCP byte sequence and holds no TLS secrets.

The implementation uses Zig 0.16.0 standard library types, pure parsers and direct
Linux syscalls. `std.process.Init.Minimal` passes arguments without initializing
`std.Io.Threaded` automatically. `std.Io.net.IpAddress.parseLiteral` supplies numeric
address parsing. Hostname backends use an explicitly scoped startup resolver that
is destroyed before the raw-syscall serving loop. Version-specific signatures were checked
against the 0.16.0 standard library, rather than pre-0.16 `std.net` examples.
See the [official release notes](https://ziglang.org/download/0.16.0/release-notes.html).

## Decision: level-triggered epoll

Readiness and completion are both viable for this workload. io_uring can batch
submissions, offers completion ownership and can later support registered buffers
or zero-copy sends. It also requires SQ/CQ sizing, buffer lifetime until completion,
cancellation discipline and completion/notification handling. Those mechanisms are
valuable when measured syscall or kernel-copy cost justifies them.

The serving loop uses epoll with nonblocking sockets. A handler can send a queued
chunk, receive the next chunk and send again without another notification round.
This is especially useful when one stream spans many buffers. It does not prove
epoll inherently faster than a pipelined io_uring implementation; strict serialized
completion relays are only one possible io_uring design.

Level triggering permits a bounded fairness quantum without an additional ready
queue. Edge triggering would require either unlimited draining or explicit retained
ready work when the quantum expires. Changing interest only when the mask changes
keeps steady bulk forwarding inexpensive. Source reads are disabled at full queues;
OUT is enabled only for queued output. A socket with no useful interest is removed,
preventing persistent hangup notifications from spinning a paused connection.
The behavior follows [Linux epoll semantics](https://man7.org/linux/man-pages/man7/epoll.7.html).

## Decision: one process, one serving thread

A single loop gives exclusive ownership of fds, queues, pools and counters. No
atomics, locks or cross-worker jobs are needed. Worker threads would preserve
share-nothing connection state but still require startup/join coordination, signal
broadcast and per-worker capacity accounting. They add little to a small deployment.

Independent processes with `SO_REUSEPORT` give optional core scaling and failure
isolation through an external service manager. They multiply capacity reservations
and divide accept load imperfectly; neither limitation is hidden. One process is
the default, `reuse_port` is opt-in, and route tables must agree across processes.
There is no speculative backend/worker abstraction.

## Ownership map

| Module | Owns or computes |
| --- | --- |
| `main.zig` | CLI, bounded config input, startup arena and daemon lifetime |
| `config.zig` | Immutable validated routes and numeric endpoints |
| `backend.zig` | IP/hostname endpoint syntax and startup-only name resolution |
| `name.zig` | Owned canonical hostname and ASCII syntax rules |
| `client_hello.zig` | Pure bytes-to-verdict parser and bounded wire cursor |
| `connection.zig` | Actual phase transitions, staged prefix, rings, EOF/FIN and deadlines |
| `buffer.zig` | Fixed ring indices and readable/writable spans |
| `pool.zig` | Single-owner freelist, token generations and stale-event checks |
| `linux_io.zig` | Socket/clock/address syscall boundary and diagnostics |
| `io_result.zig` | Value result carrying an exact Linux errno; socket side and operation types |
| `counters.zig` | Single-owner counters, error dimensions and bounded stats formatting |
| `timers.zig` | Fixed-capacity indexed deadline heap, updates and cancellation |
| `server.zig` | Admission, epoll registrations, slabs, deadlines, signals and teardown |
| `connection_test.zig` | Artificial socket operations for the same production engine |

The generic parameter in `Connection.drive` substitutes a small synchronous socket
interface for testing. It does not abstract epoll or introduce a second production
event backend. Fake operations cannot change the production phase logic.

## Connection lifecycle

```text
accept + staging slot
  → hello (absolute deadline)
  → canonical exact route or explicit fallback
  → connecting (absolute deadline, SO_ERROR on readiness)
  → relaying with pending original prefix (separate absolute deadline)
  → relaying with two bounded rings (optional sliding idle deadline)
  → close fds, return staging if retained, release connection slot
```

Admission reserves a connection slot and one staging slot. Both are startup-sized
freelists; lack of either rejects the accepted socket. No allocation occurs between
admission and release. Each batch attempts at most 64 accept4 calls, including
interrupted calls and failed pending connections. The Linux
[accept error contract](https://man7.org/linux/man-pages/man2/accept.2.html) determines
the response:

| Result | Response |
| --- | --- |
| EAGAIN/EWOULDBLOCK | End the batch without an error count |
| EINTR | Retry within the batch budget without an error count |
| ECONNABORTED, ECONNRESET, ETIMEDOUT; pending ENETDOWN, EPROTO, ENOPROTOOPT, EHOSTDOWN, ENONET, EHOSTUNREACH, EOPNOTSUPP, ENETUNREACH | Count and continue the bounded batch |
| EMFILE, ENFILE, ENOBUFS, ENOMEM, ENOSR | Count, remove listener interest, resume after 250 ms |
| Other errors, including EBADF, ENOTSOCK, EINVAL and policy denial | Count and propagate a fatal listener error; do not retry forever |

EOPNOTSUPP follows the pending-network rule because the privately owned listener
is always TCP/SOCK_STREAM. Permission failures can precede connection dequeue and
are not retried on a permanently readable listener.

Config validation rejects exact listener/backend equality and same-port loopback
destinations behind wildcard listeners (IPv4 127/8, IPv6 ::1), for routes and
fallback alike. Mapped IPv4 backends are checked as IPv4, including unicast checks.
V6ONLY keeps IPv4/mapped backends independent of an IPv6 listener on the same port.
Different ports and remote addresses remain allowed. No interface, routing or NAT
discovery is performed, so this does not prove the absence of every routing loop.

Backends and fallback accept numeric endpoints or an ASCII hostname plus an
explicit nonzero decimal port. URLs are rejected; a final hostname dot is allowed.
All resource limits, route names and endpoint syntax are validated before DNS I/O.
The listener remains numeric. `Config.parseWithResolver` substitutes only startup
lookup for unit tests; the production route/relay types still contain numeric
`IpAddress` values.

Zig 0.16.0 `HostName.lookup` uses `/etc/hosts` and the Linux resolver configuration.
Each configured hostname resolves once before bind, including `--check`. Lookup
errors prevent startup. The first IPv4 answer is selected, otherwise the first IPv6;
mapped IPv4 counts as IPv4. The selected address is checked for unicast and self
targets before it can enter a route. There is no reachability probe, rotation,
connect failover or TTL refresh. A restart applies DNS changes.

A lazy `std.Io.Threaded` instance permits at most one startup lookup worker. The
caller drains a fixed 16-result queue while lookup runs, so a large hosts/DNS answer
list cannot block on an undrained queue or grow memory. Only the first address of
each family is retained. The lookup future is joined before its name buffer/queue
leave scope, and the worker is joined and resolver resources released before
`Server.init`. Numeric-only startup does not initialize this instance. Compilation
permits that startup worker; no worker, DNS context or DNS allocation reaches the
serving path. This is separate from the single owner of all relay state.

Each connection owns two ring slices throughout its life. The prefix slice is sent
directly before any later client bytes. It is not copied into a relay ring. The
whole accumulated range is forwarded, including bytes coalesced after ClientHello.
Reverse forwarding can proceed while the prefix is being flushed. Stage ownership
ends only after that range drains or both fds close.

## Parser bounds and record fragmentation

The record cursor skips five-byte TLS headers while reading logical handshake
fields. It can read a length or name across a record boundary without assembling a
second copy. A framing pass proves the declared handshake is available; only then
does a bounded body reader validate nested vector lengths. Incomplete deliveries
usually walk record headers instead of reparsing the full extension list.

The result is `need_more`, `invalid`, or `ok(?Name)`. Name is an owned 253-byte value;
no staging slice survives routing. Record/body arithmetic widens attacker lengths
to `usize`, subtracts only after bounds checks, and never forms an unchecked slice.
Unsupported extensions are skipped, not decoded. Duplicate SNI and malformed tails
are refused rather than ignored after an early match. This is framing and route
validation; duplicate unrelated TLS extensions and full version/cipher semantics
remain the backend's responsibility.

[RFC 8446](https://www.rfc-editor.org/rfc/rfc8446.html) allows handshake messages to
span records and limits plaintext record payload to 16384 bytes. A 64 KiB total wire
cap, including headers, and 64-record cap bound staging and CPU work. The theoretical
TLS ClientHello can exceed that cap. It is a documented admission choice, not a
claim that modern clients can never exceed it.

The [ECDHE-MLKEM specification](https://datatracker.ietf.org/doc/html/draft-ietf-tls-ecdhe-mlkem-04)
defines a 1216-byte X25519MLKEM768 client share. Other shares and extensions add to
that; no 4 KiB assumption is made. Tests include multi-record 24 KiB and maximum
64 KiB wire prefixes. Actual client compatibility still requires captures and
versioned evidence; a bounded synthetic fixture does not establish every client's
behavior. Names follow [RFC 6066](https://www.rfc-editor.org/rfc/rfc6066.html) with a
deliberately strict ASCII DNS admission policy.

## Backpressure, fairness and half-close

Each direction has independent ring, read EOF and propagated write FIN. Short
sends advance ring head or prefix offset. Short reads append only to free space.
No compaction, packet allocation or unbounded read-ahead exists. A blocked write
may fill the remaining ring, then suppresses source readability. The opposite
direction remains independently schedulable.

One pump attempts at most 128 socket transfer calls and sends at most 256 KiB per turn.
EAGAIN records a local stop condition so a pump does not repeatedly retry a blocked
operation within that turn. The level-triggered interest set resumes unfinished
work. HUP/RDHUP is a hint: actual zero-byte recv establishes EOF. Data already in
the queue must drain before [SHUT_WR](https://man7.org/linux/man-pages/man2/shutdown.2.html).
Only both completed halves or a fatal event end the connection.

## Shared splice relay

An opaque buffered read of at least 16 KiB makes a stream eligible for splice;
prefix size and accumulated tiny messages do not. Activation waits for the prefix
and that direction's ring debt to drain. Splice can resume in the same callback
after draining a previous ring spill. Reads respect the remaining byte quantum
while the destination is writable, avoiding fairness-induced pipe debt. The
single serving owner lazily acquires two bounded
NONBLOCK/CLOEXEC pipes, resized to the configured ring capacity. Failure closes
partial allocations and leaves buffered forwarding available.

Each callback borrows empty pipes. Socket-to-pipe and pipe-to-socket operations
share the usual call/byte budgets. A blocked write, partial drain, budget yield
or fatal socket error reclaims every pending pipe byte before another connection
can borrow it. Live debt goes into that direction's empty ring; fatal debt is
discarded. This bounded spill can require additional pipe reads at callback exit.
An unexpected reclamation failure disables the process's pipe path and closes
the affected connection. Ring data always precedes subsequent source data and FIN.

After 32 consecutive splice reads below 1 KiB, an empty stream returns to buffered
forwarding; a later large opaque read can requalify it. The shared pipes remain
owned by Io and close once at server teardown. SIGPIPE is ignored only for the
serving lifetime so splice EPIPE follows ordinary typed failure accounting.

On a previously connected TCP socket Linux
[inet_shutdown](https://github.com/torvalds/linux/blob/master/net/ipv4/af_inet.c)
sets the shutdown bits even when TCP_CLOSE causes ENOTCONN. After EOF and all
prefix/ring debt drains, ENOTCONN completes that write half only if SO_ERROR is
clear. A pending reset or a failed SO_ERROR probe is fatal. Other shutdown errors,
including EPIPE/ECONNRESET, remain fatal; EINTR is retried. Reverse buffered data
still drains independently. Completion means no more writes, not peer delivery acknowledgement.

Epoll data encodes a 47-bit generation, 16-bit slot and one-bit fd role. Every cached
event validates occupancy and generation before touching the connection. Close
removes registrations before releasing the slot; Linux close is never retried on
EINTR. At generation exhaustion a slot is retired instead of wrapping.

## Memory, socket policy and deadlines

Two 64 KiB rings cost 128 KiB per capacity slot. The separate default staging slab
costs 64 × 64 KiB = 4 MiB, not 64 KiB for every established stream. All sizes are
startup reservations; virtual capacity, touched RSS and kernel socket memory are
different measurements. Buffer capacity above 1 GiB is rejected and startup checks
`RLIMIT_NOFILE >= 2 × max_connections + 12`. Splice-disabled builds need `+ 8`.
Shared pipe capacity is two ring sizes in kernel memory, with four process-owned
fds regardless of stream count. Pool/connection/config metadata is extra.

Startup uses NONBLOCK/CLOEXEC sockets, accept4 and a backlog of 1024. SO_REUSEADDR
permits restarting a listener; SO_REUSEPORT is only for explicit process scale-out.
IPv6 listeners are V6ONLY so the family is predictable. TCP_NODELAY avoids buffering
small forwarding writes; large streams are not expected to benefit from it alone.
Keepalive, TCP_USER_TIMEOUT and forced socket buffer sizes are deferred to workload
measurement. MSG_NOSIGNAL confines broken-pipe failure to the connection.

Hello and connect timestamps are absolute. Prefix flushing uses a fresh absolute
connect-timeout interval after connect completion, so a slow peer cannot pin all
staging indefinitely when idle expiry is disabled. Relay activity updates only on
successful byte I/O. A startup-reserved indexed min-heap holds at most one deadline
per connection slot. Insertion, cancellation and phase changes cost O(log active
timers); reading the next deadline is O(1). No periodic capacity scan remains.
On successful relay I/O only the activity timestamp changes. When the earlier
heap deadline comes due, the actual idle deadline is rechecked and postponed if
needed. This keeps ordinary packet forwarding free of heap updates. Phase changes
update immediately so a shorter connect/prefix deadline cannot hide behind an old
hello deadline. Teardown cancels before slot reuse; disabled idle removes the timer.
At most 256 due entries are processed per event batch, balancing expiration work
against socket/signal handling. These are algorithmic costs, not measured speedups.
Timer nodes and indices add 20 bytes per capacity slot on the supported 64-bit targets.

SIGINT/TERM/USR1/USR2 are blocked and consumed through signalfd in the owning loop.
Shutdown stops accepts and drains for 30 seconds; the next signal requests an
immediate stop. SIGUSR1 requests totals, while SIGUSR2 cycles runtime verbosity.
Diagnostics use fixed-buffer stderr writes and need a functioning sink.
There is no packet logging or HTTP admin server.

## Socket error observability

recvfrom/sendto and shutdown return `Result(T)`, a tagged union containing either
the successful value or the exact `std.os.linux.E`. This non-exhaustive enum retains
unrecognized numeric errno values as well. EINTR retries in the syscall wrapper;
EAGAIN ends only the current read/write drain. No mutable errno slot, allocation,
string construction or error logging crosses the boundary. Classification runs
only when a fatal result closes a connection. Successful relay operations add no
syscalls, formatting, lookup, locks or counter dimensions.

The behavior follows [recv(2)](https://man7.org/linux/man-pages/man2/recv.2.html),
[send(2)](https://man7.org/linux/man-pages/man2/send.2.html) and
[SO_ERROR](https://man7.org/linux/man-pages/man7/socket.7.html). SO_ERROR retrieves
and clears a pending error, so it is read only at the existing connect readiness,
EPOLLERR and drained-ENOTCONN sites. A successful getsockopt can carry a nonzero
pending errno; the syscall can also fail itself. Both retain their exact errno and
use the socket-probe operation, rather than attributing the outcome to a recv/send
that did not report it. A pending error following shutdown ENOTCONN is counted once
as that probe's error, not as both errors. Connect-phase SO_ERROR still belongs
exclusively to `connect_failures`.

`io_errors` remains the aggregate of fatal socket outcomes after admission,
including pre-routing client reads as before. Each event has exactly one
side/operation (`client` or `backend`, then read/write/shutdown/socket probe) and
one cause. The [README counter tables](../README.md#clienthello-and-security-limits)
define all fields. In each snapshot, the sum of the eight operation counters and
the sum of the eight cause counters separately equal `io_errors` (modulo u64 wrap).
The dimensions are marginal totals, not a per-side/errno cross-tabulation.
`last_other_io_errno` is an exact last-value gauge for unclassified errno and is
not part of either sum. Zero-byte nonempty sends have their own `zero_writes` cause
without an invented Linux errno. Accept failures and proxy deadlines remain
separate categories.

Existing failure behavior is preserved. Reset, broken pipe and other fatal socket
results close both fds. Drained shutdown ENOTCONN with clear SO_ERROR completes
only that FIN half; ordinary FIN, retry and would-block outcomes remain uncounted.
The new counters describe observed outcomes, not whether a workload should treat
them as expected or problematic.

Stats use the existing 4096-byte diagnostic capacity. A compile-time bound includes
every field name, punctuation, the newline and all u64 values at 20 digits; adding
too many fields is a compile error instead of silent truncation. A unit test formats
every field at maximum width and parses the complete JSON. Formatting happens only
for an explicitly requested or enabled JSON periodic/final snapshot.

## Live logging

`log.zig` owns the level, format and two previous counter snapshots through a Logger
borrowed by Server from main. The serving loop owns all logger mutations, including
SIGUSR2 level changes. There is no global logger, mutex, logging worker, heap queue
or per-packet formatting. Levels are filtered before formatting or wall-clock I/O.

Default text output has UTC timestamps, aligned severity labels and human-readable
byte volumes. Periodic activity uses wrapping counter differences and the current
active gauge; idle zero-activity intervals are suppressed. Warning/error differences
are consumed at most once per second, with one grouped line per severity and a final
flush on shutdown. Consuming disabled levels and resetting baselines on SIGUSR2
prevents replay of errors that occurred while muted. Counters themselves never reset.
Level changes flush enabled pending warning/activity data before resetting baselines.
The [README](../README.md#logging) defines the severity policy and signal cycle.

Detailed lifecycle output is opt-in at debug and occurs only at phase changes and
teardown. A slot stores the fatal I/O side/operation/result only on failure, without
another syscall or counter update. The ID is the generation-tagged client token,
so reused slots remain distinguishable. Logs never borrow a staged name or payload.
SIGUSR1 bypasses the verbosity threshold because it is an explicit diagnostic.
Text totals omit zero fields; JSON retains the complete existing counter schema.

Messages are bounded to 512 bytes and output lines to 4096. Counter groups have
compile-time maximum-width bounds; JSON/text escaping prevents newlines and control
bytes from forging events or terminal controls. The line bound covers six-byte JSON
escapes for every message byte. Byte-unit arithmetic remains safe at maximum u64.
Writes retry EINTR and partial writes, without growing storage; a blocked stderr can
still stall the single serving loop. Debug verbosity is intended for diagnosis.

Compose installer readiness checks an owned LISTEN socket through the container's
host PID, rather than requiring a startup log at info. Explicit --check diagnostics
stay visible even with log_level none; this preserves actionable preflight failures.

## Additional performance mechanisms

The optional `-Ddataplane_metrics=true` build records syscall outcomes, pump exits,
readiness batches, duplicate dispatch opportunities and interest transitions.
`linux_io.Io` owns its single-threaded counters; snapshots are emitted only on
SIGUSR1 as a separate `event: dataplane` JSON object. Ordinary builds use a zero-size
metrics type and compile out updates and batch bookkeeping. Production stats and
logging retain their existing schema and behavior. There are no per-packet clocks,
strings, allocation, atomics or locks in this instrumentation.

The benchmark coordinator establishes and warms all persistent streams before its
ready/go barrier. It samples proxy, generator and origin CPU around the payload
window, records boundary skew and tail drain separately, and verifies reclamation.
Both baseline and candidate use the same harness on the same runner, alternating
order across repetitions. Optional perf counters are gated at these boundaries;
capability failures remain explicit missing measurements. Metrics builds and perf
recording are diagnostic variants, with ordinary ReleaseFast results retained
separately for performance comparisons.

The selected splice path has fixed process-owned kernel queues and bounded ring
spill. send_zc would introduce page/notification lifetime bookkeeping; multishot
recv would change buffer ownership and queue handling. Alternative submission
or event-loop designs require a measured bottleneck and paired verification.
