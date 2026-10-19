---
description: Development, review and CI-parity checks for Zigveil.
---

# Development workflow

1. Read AGENTS.md and the applicable skills. Trace ownership and phase transitions
   before editing. Confirm the change serves the narrow passthrough workload.
2. Use Zig 0.17.0 API sources and Linux documentation to resolve uncertain signatures
   or semantics. Keep assumptions distinguishable from measured evidence.
3. Add focused tests for changed behavior through the production state machine.
   Parser tests must exercise malformed lengths and fragmentation under safety checks.
4. Run permitted checks on a Linux verification environment:

```sh
zig fmt --check build.zig src
zig build
zig build test
zig build -Doptimize=safe --prefix /tmp/zigveil-safe
zig build test -Doptimize=safe
zig build fuzz -Doptimize=safe
python3 -m py_compile test/*.py bench/*.py
python3 bench/harness.py smoke
python3 test/integration.py --binary zig-out/bin/zigveil
sudo python3 test/dns_integration.py --binary zig-out/bin/zigveil
zig build -Doptimize=fast
zig build test -Doptimize=fast
python3 test/integration.py --binary zig-out/bin/zigveil
sudo python3 test/dns_integration.py --binary zig-out/bin/zigveil
ulimit -n 8192
python3 test/bench_harness.py --binary zig-out/bin/zigveil
```

Docker/deployment changes additionally require shell syntax/lint, native image
builds, `python3 test/docker_smoke.py --image IMAGE`, and the Compose installer E2E
on a disposable systemd host. The normal CI runs these checks on amd64/arm64.
Full Linux validation explicitly selects amd64/arm64 baseline and amd64
x86_64_v3, matching production image profiles. Pass the matrix CPU to every build,
test, fuzz and optional benchmark-tool build. The default ordinary build is baseline.
Native images cover fast/safe on amd64/arm64 and amd64-v3; builds also verify PIE.
Linux CI caches local/global Zig compilation artifacts by compiler release, runner
OS, architecture and CPU. Per-commit keys can restore earlier compatible entries;
Zig validates source/options dependencies. Cache misses must build normally.
Resolve runner.temp in step inputs and export the compiler cache path through
GITHUB_ENV; runner context is unavailable in job-level env expressions.
Keep test/fuzz Run.has_side_effects=true so compilation reuse cannot replace actual
test execution. Bump the cache schema when changing its compatibility assumptions;
do not cache success statuses or remove any verification mode to improve timings.
Scratch image builds additionally reject PT_INTERP and DT_NEEDED in the actual
production ELF. Smoke covers direct CLI/default and explicit config arguments,
missing/invalid config, Docker hosts and embedded DNS, read-only forwarding,
active SIGTERM and restart. No shell is available in the runtime.
Manual publication builds directly, while the operator checks that ordinary Linux
CI succeeded for the source commit. Do not repeat the matrix or add run-status
queries/waits to publication. Keep Docker cache scopes aligned by architecture,
CPU profile and fast/safe mode; published digests still need smoke and platform
checks.
Mandatory shared-splice workloads use --require-workloads, so topology refusal
cannot pass CI. Use one generator there to keep correctness coverage executable
on smaller runners; separate performance experiments may require more distinct CPUs.
Adaptive relay changes cover asymmetric bulk/short traffic in both orientations,
independent activation/deactivation/reactivation, simultaneous bulk, partial I/O,
pipe reclamation and both FIN halves. Preserve memory layout and compile-out in
buffered builds; operation-count regressions do not establish measured speedups.
Logging changes verify live levels, SIGUSR1/USR2, cumulative traffic, actual elapsed
rate windows, idle suppression with active connections, fixed failure batches and
their last-event context, bounded escaping/units and unchanged JSON counters.
Cover hello/idle versus connect/prefix severity and one DEBUG close with lifetime,
config-owned route and exact errno through actual sockets and artificial I/O.
Keep daemon readiness independent of log verbosity.
Shutdown changes cover SIGTERM/SIGINT with live connections and an empty listener,
repeated signals, all four connection phases, timer/pool/fd cleanup, retained
forwarded-byte counters/final logs and reuse of the listener port. Check shared
pipe ownership and buffered builds. Use broad bounded exit waits that detect a
drain-window regression without millisecond timing or sleeps on the success path.
DNS changes preserve bounded startup/check completion with a silent resolver and
continuous malformed or duplicate replies. Deterministic ready-I/O tests cover
retry deadlines, the overall limit and socket cleanup without wall-clock timing.
TCP option changes check old defaults, explicit bounds, invalid nested JSON before
DNS, actual IPv4/IPv6 getsockopt values, preserved inherited settings, outbound
and admitted socket paths, typed setup failure/fd cleanup and bulk/FIN with opt-ins.
Do not wait for real keepalive expiry or add per-relay option calls.

5. Review the full diff for unchecked arithmetic, stale slices, prefix offsets,
   backpressure masks, FIN ordering, fd/token reuse, deadline progress and teardown.

Multi-worker changes require `test/workers.py` against debug/fast on every native
CPU profile, instrumented and buffered builds, and the scratch restart smoke.
The suite reuses existing real TLS, PROXY v2, FIN, reset and duplex cases, then
checks distinct owners, summed bytes, partition limits, acknowledged levels,
muted snapshots, repeated stop, no children and listener reclamation. Unit tests
inject comptime init/spawn/event-loop failure through the production lifecycle;
keep those hooks absent from shipping config/environment. The baseline amd64 CI
also runs safe units and real multi-worker relay with `-Dtsan=true`. Pass `--tsan`
to the worker harness only for that binary; its exact thread count includes one
sanitizer background thread. Normal builds retain strict serving-thread counts.
6. Update README, design notes, agent guides and fixtures when their contract changes.
   Source is authoritative; documents must not describe an abandoned implementation.
   Routing changes must cover classification failure, partial/empty EOF and hello
   expiry, exact prefix debt, no connect failover and timer-driven fd reconciliation.
   Fallback PROXY v2 also needs independent binary/header checks, real accepted
   endpoints, partial header/prefix writes, pooled reuse, metadata failure, real TLS
   after preamble consumption and zero queries/header on ordinary routes.
7. Check the actual workflow result for the final commit. Report which checks ran
   and any limits; absence of execution is not a passing test result.

Performance changes additionally follow the benchmark guide. Measure Zigveil
directly under reproducible workloads before making throughput claims. The manual
Benchmarks workflow records hosted-runner measurements and direct-origin controls;
inspect all repetitions and artifacts, and retain failures. Harness changes must
preserve bounded echo credit, failed-run JSON/nonzero status and cancellation cleanup.
Cover pre-measurement warmup failures as well: keep rates null, cancel/join every
owned warmup task before closing streams, and propagate external cancellation.

For dataplane work, compare baseline/candidate in one Benchmarks job. Check separate
generator/origin CPU, measurement-window skew, repeated paired deltas, tail latency
under bulk load, exact payload validation and post-drain fd ownership.
Bracket each proxy byte-counter capture with CPU samples, including tick uncertainty
when schedstat is missing. Normalize the upper CPU bound only if the aggregate
bound width is at most 1%; retain wider ranges as raw data and leave CPU/Gbit null.
Keep generator/origin CPU independent of the proxy-byte denominator.
Measure
`-Ddataplane_metrics=true` observer overhead against ordinary fast. Perf
availability is a measured capability, not a prerequisite; missing counters are null.
Run `test/bench_lab.py` against an instrumented binary and instrumented unit tests in
debug, safe and fast. safe unit coverage also checks the
buffered control. For structural dataplane changes, select an explicit production
baseline compatible with Zig 0.17.0 and compare ordinary fast builds using the same
compiler. Keep the same explicit CPU profile on candidate, baseline and diagnostic
builds; record both comparison profiles in metadata and the summary. Baseline and
diagnostic benchmark builds are opt-in. Repeat and localize any sustained regression;
inspect generated code when that diagnosis requires it.
Keep one-off profiles, disassembly and measurement output in CI artifacts or an
ignored results directory, outside the maintained source and documentation.
