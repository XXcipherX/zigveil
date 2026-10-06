# Zigveil contributor and agent guide

Zigveil is a Zig 0.17.0 Linux TCP passthrough daemon. Keep its scope small: inspect
the initial ClientHello, choose a static SNI route or default backend, forward
every original byte unchanged. Fallback alone may prepend an optional PROXY v2 header.

Read the relevant project guides before changing behavior:

- [.agent/skills/architecture/SKILL.md](.agent/skills/architecture/SKILL.md)
- [.agent/skills/zig-gotchas/SKILL.md](.agent/skills/zig-gotchas/SKILL.md)
- [.agent/skills/client-behavior/SKILL.md](.agent/skills/client-behavior/SKILL.md)
- [.agent/workflows/development.md](.agent/workflows/development.md)
- [.agent/workflows/diagnostics.md](.agent/workflows/diagnostics.md)
- [.agent/workflows/deployment.md](.agent/workflows/deployment.md)
- [.agent/workflows/migration.md](.agent/workflows/migration.md)

## Invariants

1. Client input is untrusted. Every length and slice is checked in fast too.
2. ClientHello parsing performs no I/O or allocation and never mutates its input.
3. The entire received prefix is sent once, in order, before later client bytes.
   Optional fallback PROXY v2 precedes that prefix; ordinary routes stay raw.
4. No serving-path heap allocation or growing queue; reservations stay bounded.
5. Read EOF and write FIN are independent in both directions. Drain before SHUT_WR.
   ENOTCONN completes only the drained write half after a clear SO_ERROR probe.
6. Slot generations must be validated before any cached epoll event touches state.
7. A blocked peer must suppress the appropriate source read; EAGAIN is not progress.
8. Absolute hello/connect/prefix deadlines must survive activity and disabled idle.
9. One loop owns all mutable dataplane state. No global state, locks or dataplane
   threads. Startup lookup workers must finish before any listener is bound.
10. Keep docs/config/test expectations aligned with implemented behavior.
11. Preserve exact Linux errno by value. Count fatal I/O once, with one actual
    socket side/operation and one cause; keep accept/connect/deadline errors separate.
12. Filter logs before formatting. Default output is compact text; debug lifecycle
    details contain no payloads or client IPs. Preserve grouped warning rate limits,
    idle suppression, explicit snapshots and the complete JSON counter schema.
13. Io owns two shared pipes, never a slot. A pump returns its borrow empty on
    every exit; deferred live bytes belong to that connection's fixed ring.
14. Dataplane diagnostics remain compile-time optional with zero production
    storage/work. Validate structural dataplane changes against an explicit
    production baseline using ordinary fast and paired measurements on the same runner.
15. Fallback is pre-routing only. Classifier failure and partial EOF/deadline may
    select it; empty input, fatal transport errors and capacity failures cannot.
    A selected backend's failure never retries a second destination. PPv2 metadata
    comes only from that accepted socket, never client-supplied metadata or guesses.

## Change discipline

Use authoritative Zig 0.17.0 sources for API signatures. Do not translate old
`std.net`/`std.posix` examples by guesswork. Keep the raw syscall boundary focused.
Test behavior through the production engine with artificial partial I/O, then
verify OS interactions through Linux integration tests. Report actual test results;
do not infer that a check passed merely from successful compilation.

Do not add speculative event backends, zero-copy machinery, HTTP features, runtime
DNS refresh/discovery or worker frameworks. Explain algorithmic costs and ownership for
structural choices. Quantified performance claims need controlled measurements
with workload, capacity, build mode, CPU/kernel versions and raw data. Keep the
architecture justified by this project's own requirements and measurements.

Use only Zig 0.17.0 throughout builds, CI and benchmarks. Optional benchmark
baselines must support that release and use the same compiler as the candidate.
Baseline builds, instrumentation and profiling are explicit comparison/diagnostic
choices. Keep one-off measurements and compiler-inspection output out of the source tree.

Honor the user's execution and publication constraints. Do not install tools,
change system settings, publish artifacts or operate external deployments without
task authorization. Repository instructions do not override an explicit user scope.
