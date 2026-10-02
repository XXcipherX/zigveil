---
name: zigveil-architecture
description: Runtime ownership, bounded resources, SNI routing and opaque TCP relay invariants.
---

# Architecture

## Stack and intent

- Zig 0.16.0, Linux x86_64/aarch64, standard library only, no libc dependency.
- One process, one level-triggered epoll loop, one mutable-state owner.
- Optional externally managed SO_REUSEPORT processes; limits remain per process.
- Static numeric addresses after startup hostname resolution; immutable JSON config.
- No termination, payload transformation or protocol state after the initial route.

The complete rationale is [docs/DESIGN.md](../../../docs/DESIGN.md).

## Ownership and dependency boundaries

`main.zig` owns config lifetime and startup validation. `Config` owns its parsed
JSON and Route array; its values outlive `Server`. The server owns all fds,
registrations, connection slots, freelists and byte slabs. A slot borrows exactly
two relay slices and, while needed, one staging slice. Configuration endpoints and
owned `Name` values cannot refer into a recycled staging buffer.

`connection.zig` owns connection transitions, offsets, EOF/FIN and deadlines.
`linux_io.zig` supplies synchronous nonblocking operations. `server.zig` reconciles
interest and performs teardown. `pool.zig` retains generations between uses;
reinitializing an occupied connection must never reset that metadata.

The engine's I/O type seam exists for `connection_test.zig`. It is not an async
runtime or a generic event-loop backend. Avoid dependencies from parser/buffer/pool
modules back into Server.

`backend.zig` validates IP/hostname-plus-port syntax. Config checks the whole input
before calling the startup resolver. Its one optional worker drains through a
bounded result queue and is joined before bind. The first IPv4, otherwise first
IPv6, is validated and stored as a numeric endpoint. Keep DNS resources and lookup
out of the serving path; changes to DNS require a restart. `--check` resolves names
but does not connect. Preserve unicast/self-target checks after resolution.

## State transitions

`hello → connecting → relaying → closed`, with immediate connect permitted.
`relaying` initially retains the staged prefix and an absolute prefix deadline.
The entire received range, not the parsed message length, is prefix debt. Sending
it directly avoids a staging-to-ring copy. Release staging only after debt is zero
or both fds close; later reads cannot overtake that debt.

Each ring is independently bounded. Full ring disables that source read; nonempty
ring/prefix enables destination OUT. Empty output never keeps OUT subscribed.
RDHUP/HUP is a hint, recv(0) is EOF. EOF plus drained debt causes one SHUT_WR;
reverse traffic remains allowed. Both FIN halves finish normally; errors close
both fds. Cached events validate generation and role before state access.

Bulk-eligible callbacks may borrow the serving owner's two empty splice pipes.
Always reclaim pending pipe bytes before returning, on every success/error/yield
path. Spill live debt into that connection's bounded ring; discard fatal debt.
Never carry another connection's bytes in a shared pipe across callbacks. Shared
pipes close once with Io, never with a slot. Short-message fallback, prefix order,
FIN-after-drain and typed socket failures remain the production state machine.

ENOTCONN after drained SHUT_WR completes only that half when SO_ERROR is clear;
pending errors remain fatal. Config self-target checks cover exact addresses and
wildcard loopback, with mapped IPv4 aliases and V6ONLY family separation. They do
not discover local interfaces or prove that indirect routing loops are absent.

`io_result.zig` carries either success or exact Linux errno, including unknown
values. One fatal close increments `io_errors`, one socket side/operation and one
cause. SO_ERROR probes have their own operation; do not pretend they were recv/send
failures. Connect/accept counters stay separate. Error dimensions must add to the
aggregate separately; `last_other_io_errno` is a gauge, not a third event count.
Preserve FIN/reset semantics and classify only on failure. Stats retain a fixed
buffer with a compile-time worst-case bound.

`log.zig` is owned by main and borrowed by Server. Levels/formats come from config;
SIGUSR2 changes only runtime verbosity in the serving loop. Periodic text activity
uses interval deltas; warning/error groups use independent one-second deltas.
Idle intervals and zero event fields stay quiet. JSON stats retain every counter.
SIGUSR1 explicitly requests totals even at none. Debug lifecycle metadata is emitted
only at phase transitions and close, never per packet. A fatal connection result
is retained by value for that close record; it does not add successful-I/O work.
All formatting is bounded and occurs after filtering; stderr writes may block.

## Resource and time model

Buffer capacity = `connections × 2 × ring_bytes + handshakes × 65536`.
Defaults: 1024/64 slots, 65536-byte rings, 132 MiB reserved buffer space.
Metadata and kernel socket memory are additional; virtual capacity is not RSS.
User-owned slabs allocate at startup. Splice acquires a fixed pair of kernel
pipes lazily, with at most two ring capacities and four fds per process. Startup
checks `2 × max_connections + 12` fds (`+ 8` when splice is disabled).
Do not introduce per-packet allocation, copies
for compaction, growing queues or hidden std.Io jobs.

An indexed heap holds one timer per active slot, updated on phase changes and
cancelled before release. Absolute hello/connect/prefix timestamps differ from
sliding relay activity. Positive recv/send byte counts update activity; EAGAIN,
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
