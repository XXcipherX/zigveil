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
Native images cover fast/safe on amd64/arm64 and amd64-v3; builds also verify PIE.
Logging changes verify live levels, SIGUSR1/USR2, idle suppression, grouped rate
limits, bounded escaping/units and unchanged JSON counters through actual sockets.
Keep daemon readiness independent of log verbosity.

5. Review the full diff for unchecked arithmetic, stale slices, prefix offsets,
   backpressure masks, FIN ordering, fd/token reuse, deadline progress and teardown.
6. Update README, design notes, agent guides and fixtures when their contract changes.
   Source is authoritative; documents must not describe an abandoned implementation.
7. Check the actual workflow result for the final commit. Report which checks ran
   and any limits; absence of execution is not a passing test result.

Performance changes additionally follow the benchmark guide. Measure Zigveil
directly under reproducible workloads before making throughput claims. The manual
Benchmarks workflow records hosted-runner measurements and direct-origin controls;
inspect all repetitions and artifacts, and retain failures. Harness changes must
preserve bounded echo credit, failed-run JSON/nonzero status and cancellation cleanup.

For dataplane work, compare baseline/candidate in one Benchmarks job. Check separate
generator/origin CPU, measurement-window skew, repeated paired deltas, tail latency
under bulk load, exact payload validation and post-drain fd ownership. Measure
`-Ddataplane_metrics=true` observer overhead against ordinary fast. Perf
availability is a measured capability, not a prerequisite; missing counters are null.
Run `test/bench_lab.py` against an instrumented binary and instrumented unit tests in
debug, safe and fast. safe unit coverage also checks the
buffered control. For structural cleanup, retain generated section/symbol
sizes and compare normal fast with the optimized baseline; repeat/localize
any sustained regression rather than accepting cleaner source as sufficient.
Never retain an experimental dataplane solely on a noisy
hosted-runner throughput result.
