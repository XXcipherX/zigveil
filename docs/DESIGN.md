# Architecture and decisions

## Workload and cost model

Zigveil forwards long-lived opaque TCP streams. Routing happens once; bulk copying,
kernel TCP work, syscall cost and queue scheduling dominate sustained traffic.
The proxy preserves the complete TCP byte sequence and holds no TLS secrets.

The implementation uses Zig 0.17.0 standard library types, pure parsers and direct
Linux syscalls. `std.process.Init.Minimal` passes arguments without initializing
`std.Io.Threaded` automatically. `std.Io.net.IpAddress.parseLiteral` supplies numeric
address parsing. Hostname backends use an explicitly scoped startup resolver that
is destroyed before the raw-syscall serving loop. Version-specific signatures were checked
against the 0.17.0 standard library.
See the [official release notes](https://ziglang.org/download/0.17.0/release-notes.html).

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

## Decision: one process, independent serving owners

Default `workers=1` runs the original owner in main. A comptime single-owner loop
omits worker command/heartbeat operations, and a noinline entry keeps the runtime
frame outside this stack path. Explicit `workers=2..16` creates native Linux
threads, each with its own Server, epoll, listener, pools, indexed timers, Logger
and Io. Connection.pump and its TCP state machine are unchanged.

The controller installs one signal scope before spawn. Worker config views borrow
the same immutable routes and resolved endpoints; they never deinit the original
parsed JSON. Connection/staging capacities divide the process totals exactly,
with remainders assigned by worker index. No zero-capacity owner is admitted.
There is no elastic pool transfer: local exhaustion can reject a new flow while
another owner has free slots. Linux reuseport hashes new connections; it does
not balance bytes or application capacity and never migrates accepted sessions.
Multiple workers enable reuseport automatically; with one owner the explicit
reuse_port flag retains its behavior. External processes still have independent
process limits and require coordinated route tables.

`runtime.zig` initializes every Server and thread before releasing a serving gate.
Partial init/spawn failure wakes STOP and joins the started prefix before restoring
signals or freeing controller fds. Each worker closes its listener before error
teardown, then publishes final counters with release ordering. A failed loop stops
its peers. Thirty-second heartbeat/cleanup bounds terminate a wedged process
instead of freeing memory still owned by a thread; ordinary shutdown has no drain
delay. Panic remains a process failure.

Each owner has a separate eventfd. Command bits coalesce START/STOP/SNAPSHOT/LEVEL,
with STOP taking priority. Requested snapshots publish a generation with release;
the controller acquires every owner and copies all values before a second request.
Final snapshots have separate storage so unexpected exit cannot race a reader.
No atomic byte accounting or payload handoff is added. Multi-owner loops check
commands per epoll batch and publish at most one heartbeat per second.

Live totals cover nearby sampling times. Periodic INFO is emitted once by the
controller; SIGUSR1 also identifies each worker. SIGUSR2 publishes one absolute
level and waits for snapshot acknowledgements before announcing it. Worker-local
failure batches retain their bounded rate. Complete log writes use a cold futex
mutex; no I/O/counter/command locks are held while joining. The uncommon errno
gauge is published atomically only on fatal uncommon errors, never summed.
stderr backpressure remains a transport limitation, including for the controller.

Auto mode is deliberately absent. Affinity count does not describe cgroup CPU
bandwidth, sibling competition, available memory or a network bottleneck.
Choosing explicit N at startup keeps the default behavior predictable.

## Ownership map

| Module | Owns or computes |
| --- | --- |
| `main.zig` | CLI, bounded config input, startup arena and daemon lifetime |
| `config.zig` | Immutable validated routes and numeric endpoints |
| `backend.zig` | IP/hostname endpoint syntax and startup-only name resolution |
| `startup_dns.zig` | Hosts/localhost lookup and bounded DNS search/query construction |
| `name.zig` | Owned canonical hostname and ASCII syntax rules |
| `client_hello.zig` | Pure bytes-to-verdict parser and bounded wire cursor |
| `proxy_protocol.zig` | Bounded fallback-only PROXY v2 encoding of socket endpoints |
| `connection.zig` | Actual phase transitions, staged prefix, rings, EOF/FIN and deadlines |
| `buffer.zig` | Fixed ring indices and readable/writable spans |
| `pool.zig` | Single-owner freelist, token generations and stale-event checks |
| `linux_io.zig` | Socket/clock/address syscall boundary and diagnostics |
| `relay_pipe.zig` | Owner-local pipe handles and callback-local borrowed debt |
| `runtime.zig` | Multi-owner startup gate, signal coordination, snapshots, stop/join |
| `signals.zig` | Process signal mask, signalfd and scoped SIGPIPE disposition |
| `worker_control.zig` | Cold eventfd commands, snapshot publication and complete log writer |
| `io_result.zig` | Value result carrying an exact Linux errno; socket side and operation types |
| `counters.zig` | Single-owner counters, error dimensions and bounded stats formatting |
| `metrics.zig` | Compile-time optional dataplane diagnostics, zero storage when disabled |
| `log.zig` | Single-owner verbosity, interval baselines and bounded output |
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
  → canonical exact route or default pre-routing fallback
  → connecting (absolute deadline, SO_ERROR on readiness)
  → relaying with pending optional fallback header + original prefix (absolute deadline)
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

The startup lookup uses Zig 0.17.0 networking/DNS types with project-owned
search-name bounds. It reads `/etc/hosts` first, handles localhost, then takes one
Linux resolver configuration snapshot for all search candidates and queries.
Invalid or overlong composed names are skipped before copying/query encoding;
valid search/ndots behavior and the final bare-name lookup are preserved.
Reject zero DNS attempts before transport setup or retry-time division; this is a
normal startup error, including `--check`. Hosts/localhost resolution bypasses it.
Each queried name has a boot-clock deadline from the resolver timeout setting.
Clamp each retry deadline to that overall deadline and check the clock before
every receive batch: ready datagrams can complete an I/O operation even after its
timeout expires. Discarded packets, duplicate answers and immediate receive errors
must not keep a retry alive indefinitely. Exhaustion returns `NameServerFailure`.
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
permits that startup worker; no lookup worker, DNS context or DNS allocation reaches
the serving path. All owners share the resolved immutable endpoint snapshot.

Each connection owns two ring slices throughout its life. The prefix slice is sent
directly before any later client bytes. It is not copied into a relay ring. The
whole accumulated range is forwarded, including bytes coalesced after ClientHello.
Reverse forwarding can proceed while the prefix is being flushed. Stage ownership
ends only after that range drains or both fds close.

### Default backend selection

Previously only `ok` with unknown/missing SNI could select fallback; invalid input,
EOF and hello expiry closed. Now classification failure can select the same
default endpoint before any backend exists. Known SNI remains an exact route.
Malformed/non-TLS input, wire/record caps and partial clean EOF select fallback
if configured; otherwise retain invalid-hello close. Empty clean EOF closes
normally without a backend or invalid event. Partial input at the absolute hello
deadline selects fallback after checking pending client SO_ERROR; empty expiry
still closes. Fatal transport errors and capacity exhaustion close without fallback.

Endpoint selection is shared by these paths and creates exactly one backend.
Immediate/asynchronous connect failure, a fallback failure and later relay errors
never retry another destination. Partial EOF records the forward read half as EOF;
the backend receives FIN only after header/prefix debt. Partial timeout keeps that
read half open. It enters fresh finite connect/prefix phases; a slow default backend
cannot retain staging indefinitely. Timer-driven selection must reconcile the new
backend fd, event roles, staging ownership and deadline just like event-driven
selection. Idle timer postponement remains lazy and the established pump unchanged.

`routed` retains all selected endpoints and `fallback_routed` is its subset.
Unknown/missing/invalid observations survive successful forwarding; partial hello
timeout increments `timeouts`, not `invalid_client_hello`. These classification
counters describe input, not the number of dropped connections.

### Optional fallback preamble

Only `fallback_proxy_protocol: 2` with a selected fallback calls getpeername and
getsockname on the accepted client fd. The destination is its actual local
endpoint, not the configured wildcard or backend address. Ordinary routes never
query, encode or copy a header, even if their endpoint equals fallback's endpoint.
`proxy_protocol.zig` writes the standard v2 PROXY/TCP header without TLVs: 28 bytes
for IPv4 and 52 for IPv6, network-order addresses/ports and address length 12/36.
Mapped pairs normalize to IPv4; two raw IPv6 endpoints retain IPv6 when only one
is mapped. Mixed native/unsupported families reject without fabricated metadata
or errno. Query errors retain their exact client/socket-error cause. No backend fd
is created until preparation succeeds. No inbound PROXY header is interpreted.

PP-enabled configurations reserve 52 spare bytes per staging slot. Inspection is
still at most 65536 bytes. Preparation moves the original prefix once in that
slice, prepends the small stack-encoded header and uses the existing `stage_sent`
offset for both. One u8 records unsent generated bytes so forwarded payload
counters exclude the preamble. Actual send budgets, activity and diagnostic send
bytes include it. Partial header sends, EAGAIN and async connect therefore share
the existing debt/FIN/error machinery; reverse output stays independent. After
staging drains the same buffered/splice relay runs without header processing.
Connection.init resets all offsets/header state when a pooled slot is reused.

The [PROXY v2 specification](https://www.haproxy.org/download/3.2/doc/proxy-protocol.txt)
defines this preamble. A backend must consume it before its TLS/data parser and
trust only authorized senders. Raw fallback remains byte-transparent by default;
PP-enabled fallback adds framing while preserving every original byte. The daemon
produces no protocol responses and does not terminate TLS.

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
TLS ClientHello can exceed that cap. It is a documented SNI inspection bound, not a
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

An opaque buffered read of at least 16 KiB makes that direction eligible for splice;
prefix size and accumulated tiny messages do not. Activation waits for the prefix
and that direction's ring debt to drain. Splice can resume in the same callback
after draining a previous ring spill. Reads respect the remaining byte quantum
while the destination is writable, avoiding fairness-induced pipe debt. The
each serving owner lazily acquires two bounded
NONBLOCK/CLOEXEC pipes, resized to the configured ring capacity. Failure closes
partial allocations and leaves buffered forwarding available.

Each callback borrows empty pipes. Socket-to-pipe and pipe-to-socket operations
share the usual call/byte budgets. A blocked write, partial drain, budget yield
or fatal socket error reclaims every pending pipe byte before another connection
can borrow it. Live debt goes into that direction's empty ring; fatal debt is
discarded. This bounded spill can require additional pipe reads at callback exit.
An unexpected reclamation failure disables that owner's pipe path and closes
the affected connection. Ring data always precedes subsequent source data and FIN.

Eligibility and consecutive short-read counts belong to Direction. After 32
consecutive splice reads below 1 KiB, that direction returns to buffered forwarding
once its own debt is empty; a later large opaque read can requalify it. Opposite
bulk reads cannot reset its counter, activate it or disable its bulk mode. This
avoids forcing short-message traffic through splice solely because the other
direction is bulk, and removes the other ring's emptiness from deactivation.
The thresholds and per-direction work budgets stay unchanged. Two adaptive fields
fit the existing Direction padding on supported CI targets; the corresponding
connection-wide fields are removed. One mode check runs at each pump entry,
replacing the connection-wide check. No new allocation, pipe, queue or syscall is
added by selection itself; actual CPU/throughput effects depend on traffic.
Pipe allocation failure remains connection-wide because the serving owner's
shared pair is unavailable to both directions. The shared pipes remain
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
costs 64 × 64 KiB = 4 MiB, not 64 KiB for every established stream. PROXY v2 adds
`52 × max_handshakes` bytes only when enabled (3328 bytes at default capacity).
All sizes are
startup reservations; virtual capacity, touched RSS and kernel socket memory are
different measurements. Buffer capacity above 1 GiB is rejected and startup checks
`RLIMIT_NOFILE >= 2 × max_connections + 12`. Splice-disabled builds need `+ 8`.
Shared pipe capacity is two ring sizes per owner, with four owner-local fds
regardless of stream count. For N>1 check `2*C+8*N+8` fds, or `2*C+4*N+8` without
splice. Pool/connection/config metadata and native thread stacks are extra.

Startup uses NONBLOCK/CLOEXEC sockets, accept4 and a backlog of 1024. SO_REUSEADDR
permits restarting a listener; SO_REUSEPORT groups internal worker listeners and
can also support explicitly coordinated external processes.
IPv6 listeners are V6ONLY so the family is predictable. TCP_NODELAY avoids buffering
small forwarding writes; large streams are not expected to benefit from it alone.
Keepalive and TCP_USER_TIMEOUT are explicit opt-ins; see [Optional TCP liveness](#optional-tcp-liveness).
Omitted options preserve OS defaults; socket buffer sizes are not forced.
MSG_NOSIGNAL confines broken-pipe failure to the connection.

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

With workers=1, SIGINT/TERM/USR1/USR2 are blocked and consumed through signalfd
in the owning loop. Multi-owner signal flow is described above.
The first SIGINT/SIGTERM sets a boolean stop request, removes the
listener registration and closes the listener once. After consuming the signal
batch, run leaves event dispatch immediately, without processing further socket
events or timers. The existing drop path marks live slots as stopping, cancels
their timers, removes both socket registrations, closes both fds and returns their
staging/connection reservations. Each close decrements active and increments closed
once; shutdown does not fabricate I/O errors or forwarded bytes. Unsent prefix/ring
bytes may be discarded. Repeat stop signals leave the stop request unchanged.
Pumps have already returned every shared-pipe borrow before signalfd is handled.
Server.deinit therefore owns pipe/epoll closure, pool/timer storage and both buffer
slabs. The single owner also restores its Signals scope; the multi-owner controller
does so after all joins. Server finds no live slots after
a normal run exit. SIGUSR1 requests totals, while SIGUSR2 cycles runtime verbosity.
Diagnostics use fixed-buffer stderr writes and need a functioning sink.
Enabled pending failure batches and final totals are logged after connection
cleanup. No connection-drain wait or shutdown configuration is added.
There is no packet logging or HTTP admin server.
The Compose installer updates by recreating its container. New accepts pause
through shutdown and replacement startup, and existing streams are interrupted.
SO_REUSEADDR permits the replacement to bind the released listener port. There is
no zero-downtime guarantee. Compose stop_grace_period=35s, native systemd's 35s
stop timeout and the Compose wrapper's 45s timeout remain emergency watchdogs;
they do not impose a minimum wait when the daemon exits earlier.

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

The same client/socket operation accounts for failed fallback PROXY peer/local
endpoint queries. A partial hello deadline probes pending client SO_ERROR before
selection, so a known transport error cannot be counted as routing fallback.

`io_errors` remains the aggregate of fatal socket outcomes after admission,
including pre-routing client reads as before. Each event has exactly one
side/operation (`client` or `backend`, then read/write/shutdown/socket query) and
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
The counters describe observed outcomes, not whether a workload should treat
them as expected or problematic.

Stats use the existing 4096-byte diagnostic capacity. A compile-time bound includes
every field name, punctuation, the newline and all u64 values at 20 digits; adding
too many fields is a compile error instead of silent truncation. A unit test formats
every field at maximum width and parses the complete JSON. Formatting happens only
for an explicitly requested or enabled JSON periodic/final snapshot.

## Live logging

`log.zig` owns the level, format, one previous counter snapshot and fixed warning/error
batches through a Logger borrowed by Server from its owner. The serving loop owns all
logger mutations. Multi-worker mode has one local Logger per owner and a controller
Logger for aggregate statistics; only complete writes share a cold mutex. There
is no logging thread, heap queue or per-packet formatting. Levels are filtered
before formatting or wall-clock I/O.

Default text output has UTC timestamps, aligned severity labels and human-readable
byte volumes. Text INFO contains the current active gauge, cumulative original-stream
up/down bytes since startup, and average up/down rates. Rate numerators use wrapping
byte-counter differences; denominators use actual monotonic elapsed milliseconds,
including when the event loop wakes late. Scaled totals and rates have two decimals.
Unchanged traffic/active gauges suppress the line even with live idle connections.
JSON periodic stats still observe changes in all original counters.

Server records warning/error events only on admission failures and teardown. Fixed
batches distinguish backend connect failure, connect/prefix expiry, the exhausted
connection/handshake pool, accept resource pressure, socket setup, unsupported
metadata and network I/O failure. One grouped line per severity is emitted at most
once per second. Its counts cover all events, while `last:` describes only the most
recent event's phase/endpoint/errno. There are no per-backend maps or growing queues.
Hello/idle expiry, invalid or unknown names, ECONNRESET and EPIPE remain in full
diagnostics/debug, without automatic warnings. Other unexpected I/O errors and zero
writes remain ERROR. No reset-count threshold escalates their severity.
Shutdown and level changes flush enabled pending batches. Disabled levels discard
events; advancing summary baselines and resetting batches on SIGUSR2 prevents replay
when logs resume. Raw counters never reset.
The [README](../README.md#logging) defines the severity policy and signal cycle.

Detailed lifecycle output is opt-in at debug and emits one final record at teardown.
A slot retains acceptance time, the configured route pointer/fallback flag, final
phase and exact fatal connect/I/O result by value. Immediate and asynchronous connect
failures keep their errno, while remaining separate from relay `io_errors`.
Lifetime uses the loop's existing monotonic batch timestamp, without another clock
syscall per close. A partial hello deadline selecting fallback is retained as a flag.
The ID is the generation-tagged client token, so reused slots remain distinguishable.
Route pointers refer to immutable config that outlives Server; no staged name or
payload slice survives. No new successful recv/send/splice bookkeeping is needed.
SIGUSR1 bypasses the verbosity threshold because it is an explicit diagnostic.
Text totals omit zero fields; JSON retains the complete existing counter schema.

Messages are bounded to 640 bytes and output lines to 4096. Counter groups have
compile-time maximum-width bounds; JSON/text escaping prevents newlines and control
bytes from forging events or terminal controls. The line bound covers six-byte JSON
escapes for every message byte. Byte-unit arithmetic remains safe at maximum u64.
Writes retry EINTR and partial writes, without growing storage; a blocked stderr can
still stall its owner and a shared sink can stall control. debug verbosity is intended for diagnosis.

Compose installer readiness checks an owned LISTEN socket through the container's
host PID, rather than requiring a startup log at info. Explicit --check diagnostics
stay visible even with log_level none; this preserves actionable preflight failures.

## Optional TCP liveness

Raw config has a nullable tcp_keepalive object with explicit idle_seconds,
interval_seconds and probes, plus a separate tcp_user_timeout_ms defaulting to
zero. Validation precedes DNS/bind: keepalive seconds are 1..32767, probes 1..127,
and user timeout 0..2147483647 ms, matching Linux's positive int option bounds.
No partial object, unknown nested field or numeric overflow is accepted.

Each owner's Io stores these settings once. Its configureSocket retains NODELAY,
sets the keepalive parameters before enabling SO_KEEPALIVE, and sets USER_TIMEOUT
only for a nonzero value. Defaults perform only the previous NODELAY call and do
not overwrite inherited/kernel options. Server applies setup after capacity
checks but before acquiring a slot; outgoing setup runs before connect. A client
setup failure closes the fd, increments rejected and warns with client/errno
context. Outgoing setup returns its exact errno as a connect failure and closes
the untransferred fd once. No relay-event calls, allocations, connection policy
fields, added timers or counter schema changes are needed.

Keepalive operates on idle TCP peers without outstanding transmit work. User
timeout limits unacknowledged data and zero-window kernel queue stalls, including
TCP closing states; a quiet peer alone does not trigger it. With keepalive, Linux
checks elapsed idle time after an unanswered probe against user timeout instead
of the probe count. Neither changes the keepalive cadence. Current SYN retry
paths can also consult user timeout; it never replaces the proxy connect limit.
Kernel probes/ACKs do not pass through recv/send and do not refresh stream activity
or byte counters. All application phase/idle deadlines remain independent. Kernel
ETIMEDOUT uses existing typed connect or I/O accounting, not application timeouts.
Aggressive opt-in settings can abort healthy but temporarily disconnected peers;
no preset is enabled or presented as universally best.

Bounds and timing follow [tcp.c](https://github.com/torvalds/linux/blob/master/net/ipv4/tcp.c),
[tcp.h](https://github.com/torvalds/linux/blob/master/include/net/tcp.h) and
[tcp_timer.c](https://github.com/torvalds/linux/blob/master/net/ipv4/tcp_timer.c).

## Minimal container runtime

The production executable does not link libc; its Linux syscall boundary and
startup resolver require no distribution libraries or NSS modules. The Docker
builder checks the actual fast/safe PIE for ET_DYN, absence of PT_INTERP and
absence of DT_NEEDED before copying it to `scratch`. This gate covers baseline
amd64/arm64 and amd64-v3 images without changing executable build settings.

The runtime contains the binary and an inactive documentation example. Docker
provides hosts/resolver files; UTC formatting needs no timezone database and the
opaque stream needs no CA certificates. An exec-form ENTRYPOINT starts Zigveil as
PID 1; CMD supplies the default config path. Explicit arguments use the same
native CLI and bounded config diagnostics, including missing/invalid files.
No shell, writable startup setup or init process is required. Existing host
networking, read-only mounts, capabilities, signals and stop watchdogs are retained.
Operational inspection uses host tools and container logs. The smaller filesystem
does not change serving buffers or establish a forwarding performance gain.

## Measurement and compile-time diagnostics

The optional `-Ddataplane_metrics=true` build records syscall outcomes, pump exits,
readiness batches and interest transitions.
Each `linux_io.Io` owns its local counters; diagnostic snapshots are emitted only on
SIGUSR1 as a separate `event: dataplane` JSON object. Ordinary builds use a zero-size
metrics type and compile out counter updates. Production stats and
logging retain their existing schema and behavior. There are no per-packet clocks,
strings, allocation, atomics or locks in this instrumentation.

The benchmark coordinator establishes and warms all persistent streams before its
ready/go barrier. It samples proxy, generator and origin CPU around the payload
window, records boundary skew and tail drain separately, and verifies reclamation.
Both baseline and candidate use the same harness on the same runner, alternating
order across repetitions. Optional perf counters are gated at these boundaries.
Each proxy's SIGUSR1 counter capture is bracketed by CPU samples. Interior/exterior
CPU deltas give lower/upper bounds for the byte-counter interval, with tick
quantization accounted for if schedstat is unavailable. CPU/Gbit uses the upper
bound only when its uncertainty is at most 1%; wider bounds retain raw evidence
but no normalized point metric. Multiple proxies sum bounds before this gate.
Perf encloses counter collection and includes its diagnostic overhead;
capability failures remain explicit missing measurements. Metrics builds and perf
recording are diagnostic variants, with ordinary fast results retained
separately for performance comparisons.

The selected splice path has fixed owner-local kernel queues and bounded ring
spill. send_zc would introduce page/notification lifetime bookkeeping; multishot
recv would change buffer ownership and queue handling. Alternative submission
or event-loop designs require a measured bottleneck and paired verification.

## Dataplane choices

The retained dataplane uses 64 KiB rings, two owner-local pipes, a 256 KiB/128-call
quantum per direction and adaptive return to buffered I/O for short messages.
`relay_pipe.Pipe` stores handles owned by Io. `Borrowed` stores only a callback's
handle copy, pending debt and page-pressure pause. A pump's defer empties its pipe
on every exit; `assertPipesReturned` verifies this before a slot is recycled.
Spilled bytes belong to the connection's ring and precede later socket input.
Exclusive serving ownership makes another connection's concurrent borrow of that pair impossible.

| Choice | Cost and ownership contract |
| --- | --- |
| Two owner-local pipes | Four extra fds per owner, independent of connection count; every callback returns its borrow empty. |
| Default 64 KiB rings | Startup-bounded storage; spills preserve byte order and resume the shared path after draining. |
| Direct event dispatch | Role/generation checks precede each drive; no second ready queue or cached per-direction readiness state. |
| 256 KiB / 128-call quantum | Bounds per-direction work per dispatch while allowing a stream to span several buffers. |
| Portable CPU baseline | The ordinary binary uses baseline CPU requirements; the Docker amd64-v3 profile is an explicit alternative. |
| Adaptive buffered I/O | Each drained short-message direction returns to buffered forwarding and may reactivate splice for later bulk data independently of its peer direction. |

For dataplane changes, select an explicit production revision supporting Zig 0.17.0
and compare ordinary fast builds on the same runner. Keep rings, chunk/credit,
process count and build settings matched. Measure loaded latency and actor CPU
alongside throughput; diagnostic builds are separate opt-in variants. Current
benchmark usage and output are documented in [bench/README.md](../bench/README.md).
