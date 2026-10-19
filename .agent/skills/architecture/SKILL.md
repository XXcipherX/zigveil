---
name: zigveil-architecture
description: Runtime ownership, bounded resources, SNI routing and opaque TCP relay invariants.
---

# Architecture

## Stack and intent

- Zig 0.17.0, Linux x86_64/aarch64, standard library only, no libc dependency.
- One process, 1..16 independent level-triggered epoll owners; default one.
- Optional externally managed SO_REUSEPORT processes; limits remain per process.
- Static numeric addresses after startup hostname resolution; immutable JSON config.
- No termination or payload parsing after selection. Fallback alone may add an
  optional PROXY v2 preamble before the unchanged client stream.

The complete rationale is [docs/DESIGN.md](../../../docs/DESIGN.md).

## Ownership and dependency boundaries

`main.zig` owns config lifetime and startup validation. `Config` owns its parsed
JSON and Route array; its values outlive `Server`. `lookupRoute` lends a const Route
pointer; configuration tests use the same lookup entry point as the production
connection engine. The server owns all fds, registrations, connection slots,
freelists and byte slabs. A slot borrows exactly
two relay slices and, while needed, one staging slice. Configuration endpoints and
owned `Name` values cannot refer into a recycled staging buffer.

`runtime.zig` coordinates multiple owners only when workers > 1. Its fixed worker
array and log writer must be initialized in place before spawn. Borrowed Config
views share immutable routes/JSON but contain partitioned C/H; never deinit them.
Each worker owns all Server cleanup, including its listener before error teardown.
The controller owns its signalfd, completion fd and each control fd until joins.
Initialize every worker before releasing START. STOP supersedes other commands.
Preserve SNAPSHOT/LEVEL if they coalesce with START at the gate.

Separate requested and final snapshots. Release/acquire generation publication
protects plain counters; never read Server.counts from the controller or overwrite
a requested snapshot before it is consumed. Only final counters are exact after
join. Live captures have nearby sampling times. Counter sums exclude errno;
diagnostic maxima use max. Keep the uncommon errno publication on failure only.
No atomic byte increments, socket handoff or shared relay pipe pair is allowed.
Single-owner runLoop(false) must compile out control/heartbeat work.

`connection.zig` owns connection transitions, offsets, EOF/FIN and deadlines.
`linux_io.zig` supplies synchronous nonblocking operations. `server.zig` reconciles
interest and performs teardown. `pool.zig` retains generations between uses;
reinitializing an occupied connection must never reset that metadata.

Each owner's Io holds the configured optional TCP settings. configureSocket applies NODELAY
and explicit keepalive/user timeout once on admission or before backend connect;
defaults leave those kernel options untouched. Failed client setup closes before
pool acquisition and counts rejected with errno context; outgoing failure closes
before fd transfer and remains a connect failure. Keep stream deadlines and byte
accounting independent of kernel probes/ACKs; no relay-event socket setup is allowed.

The engine's I/O type seam exists for `connection_test.zig`. It is not an async
runtime or a generic event-loop backend. Avoid dependencies from parser/buffer/pool
modules back into Server.

`backend.zig` validates IP/hostname-plus-port syntax. Config checks the whole input
before calling the startup resolver. Its one optional worker drains through a
bounded IpAddress queue and is joined before bind. The first IPv4, otherwise first
IPv6, is validated and stored as a numeric endpoint. Keep DNS resources and lookup
out of the serving path; changes to DNS require a restart. `--check` resolves names
but does not connect. Preserve unicast/self-target checks after resolution.
`startup_dns.zig` checks composed search names before copying or query encoding,
using one resolver snapshot per lookup. Preserve hosts/localhost precedence and
absolute names; skip invalid/overlong search candidates without querying them.
Each queried name has an absolute DNS deadline; clamp retry deadlines to it and
check time before every receive batch. Queued discarded replies cannot extend lookup.

## State transitions

`hello → connecting → relaying → closed`, with immediate connect permitted.
`relaying` initially retains the staged prefix and an absolute prefix deadline.
The entire received range, not the parsed message length, is prefix debt. Sending
it directly avoids a staging-to-ring copy. Release staging only after debt is zero
or both fds close; later reads cannot overtake that debt.

Fallback is a default pre-routing destination: unknown/missing SNI, classifier
failure, partial EOF and partial hello deadline may select it. Empty input, fatal
transport errors and admission exhaustion never do. Selected backend failures
never reroute. A partial deadline checks pending client SO_ERROR, then enters
bounded connect/prefix phases; Server must reconcile the new fd and timer.

Only selected fallback with PROXY v2 queries accepted peer/local endpoints and
prepends 28/52 bytes to staging headroom. The existing prefix offset handles all
partial writes; generated bytes are excluded from payload counters. Keep parser
inspection capped at 65536 independently of headroom. Known routes perform no
metadata queries, encoding or copying. Unsupported metadata rejects, exact query
errno uses client/socket-error accounting, and pooled init clears header state.

Each ring is independently bounded. Full ring disables that source read; nonempty
ring/prefix enables destination OUT. Empty output never keeps OUT subscribed.
RDHUP/HUP is a hint, recv(0) is EOF. EOF plus drained debt causes one SHUT_WR;
reverse traffic remains allowed. Both FIN halves finish normally; errors close
both fds. Cached events validate generation and role before state access.

Bulk-eligible callbacks may borrow the serving owner's two empty splice pipes.
Always reclaim pending pipe bytes before returning, on every success/error/yield
path. Spill live debt into that connection's bounded ring; discard fatal debt.
Never carry another connection's bytes in a shared pipe across callbacks. Shared
pipes close once with Io, never with a slot. `relay_pipe.Pipe` is the owned handle;
`Borrowed` carries only a pump's handle copy and debt. `assertPipesReturned` checks
null borrows at teardown; it must not become a late drain or resource-release path.
Adaptive eligibility and consecutive short-read counts belong to Direction.
Check deactivation at pump entry only against that direction's debt. Keep the
16 KiB activation, 1 KiB short-read and 32-read thresholds, owner-local pair and
connection-wide allocation-failure fallback. Opposite traffic must not activate,
reset or deactivate its peer's adaptive state. The fields fit existing Direction
padding in supported CI builds; verify both splice-enabled and buffered layouts.
Short-message fallback, prefix order,
FIN-after-drain and typed socket failures remain the production state machine.

ENOTCONN after drained SHUT_WR completes only that half when SO_ERROR is clear;
pending errors remain fatal. Config self-target checks cover exact addresses and
wildcard loopback, with mapped IPv4 aliases and V6ONLY family separation. They do
not discover local interfaces or prove that indirect routing loops are absent.

`io_result.zig` carries either success or exact Linux errno, including unknown
values. One fatal close increments `io_errors`, one socket side/operation and one
cause. SO_ERROR probes have their own operation; do not pretend they were recv/send
failures. Connect/accept counters stay separate. Error dimensions must add to the
aggregate separately; fallback peer/local address queries use client/socket_error
too and preserve the exact errno. `last_other_io_errno` is a gauge, not a third event count.
Preserve FIN/reset semantics and classify only on failure. Stats retain a fixed
buffer with a compile-time worst-case bound.

`log.zig` is owner-local; main retains the aggregate Logger in multi-worker mode.
Levels/formats come from config; SIGUSR2 changes all owners through an acknowledged
absolute-level command. The cold Writer mutex covers complete output lines only.
Periodic text INFO shows
cumulative up/down totals and rates from wrapping byte deltas over actual monotonic
elapsed time. Suppress unchanged traffic/active gauges, even with idle connections.
Only the two forwarded-byte counters need periodic deltas. Retain the complete
previous snapshot for JSON change detection; JSON stats retain every original
counter. Warning/error events enter fixed batches
on cold failure paths; each owner emits at most one line per severity per second. Counts cover
the batch and `last:` labels only its most recent event's context. Hello/idle expiry
and reset/pipe outcomes stay in diagnostics/debug; connect/prefix expiry and actual
admission/resource pressure warn. No arbitrary reset-count escalation.
SIGUSR1 explicitly requests totals even at none. DEBUG emits one close record with
lifetime, configured route and final phase/reason, never per packet or every phase.
Acceptance time and config-owned route pointers are lifecycle metadata; the loop's
existing timestamp supplies close lifetime. Fatal connect/I/O errno is retained by
value for that close record without another probe or successful-I/O work.
All formatting is bounded and occurs after filtering; stderr writes may block.

SIGTERM/SIGINT set an immediate stop request, unregister/close the listener once
and leave event dispatch after the signal batch. Do not drive further cached
socket events or expiry work. Existing drop handles hello/connect/prefix/relay:
cancel the timer, DEL registered socket roles, close both fds, return staging and
release the slot, updating active/closed once. Queued userspace bytes may be
discarded; stopping does not count as an I/O error. Final enabled logs follow drop.
Every pump has already returned its borrow, so shared pipes remain Io-owned until
Server.deinit closes its pipes/epoll and frees pools/slabs. The single owner also
owns its Signals scope; multi-worker Signals restore only after all joins. Repeated
stop signals must not close the listener again. The stop state is a boolean request,
not a future deadline. There is no session drain window;
Docker/systemd timeouts are emergency limits.

## Resource and time model

Buffer capacity = `connections × 2 × ring_bytes + handshakes × (65536 + headroom)`.
Headroom is 52 only with fallback PROXY v2 enabled, otherwise zero.
Defaults: 1024/64 slots, 65536-byte rings, 132 MiB reserved buffer space.
Metadata and kernel socket memory are additional; virtual capacity is not RSS.
User-owned slabs allocate at startup. Splice acquires a fixed pair of kernel
pipes lazily, with at most two ring capacities and four fds per owner. Startup
checks `2 × max_connections + 12` fds for N=1 (`+ 8` when splice is disabled).
For N>1 use `2*C+8*N+8` or `2*C+4*N+8` without splice. requiredFds is the shared
formula. Server/Runtime validate before allocating serving resources; main checks
the same limit separately only for --check. C/H are process totals:
divide with remainders; require both >= N; never clone whole slabs per owner.
Explicit workers is 1..16 with default 1; no auto or forced affinity.
Do not introduce per-packet allocation, copies
for compaction, growing queues or hidden std.Io jobs.

An indexed heap holds one timer per active slot, updated on phase changes and
cancelled before release. Absolute hello/connect/prefix timestamps differ from
sliding relay activity. Positive recv/send/splice byte counts update activity; EAGAIN,
readiness and EOF do not. Idle deadlines are rechecked lazily when the stored
deadline is due, avoiding per-packet heap changes. Prefix expiry remains enabled
when idle expiry is disabled. Socket and expiration quotas bound each event batch.
Accept's 64-attempt budget includes EINTR and per-connection network failures.
Only resource pressure pauses listener interest; fatal accept failures stop serving.

## Change review checklist

Trace ownership across every failure exit and pool release. Check both fd roles
and stale batched events. Check every partial-send offset and prefix ordering.
Exercise both FIN orders, resets, held buffers, timer expiry and slot reuse. If a
new bound or config key is necessary, validate it before bind and document units,
per-process semantics and the memory formula. Explain algorithmic costs and
ownership for structural changes; measure workloads before claiming a throughput
or latency improvement or choosing capacity limits from performance results.
Review the [dataplane choices](../../../docs/DESIGN.md#dataplane-choices) before
changing event dispatch, readiness handling, fairness quanta or pipe ownership.
Dataplane changes must preserve paired ordinary fast performance, including loaded
latency and CPU/Gbit, with an explicit Zig 0.17.0 baseline. Diagnostic benchmark
builds are opt-in and measure the observer effect.
