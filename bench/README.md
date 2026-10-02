# Streaming benchmarks

This directory provides optional workload and measurement tools for Zigveil.
It contains no runtime dependencies. No proxy performance results are published
here yet; the smoke test establishes only that the harness works.

## Workload and topology

`harness.py` sends a synthetic ClientHello to an opaque TCP echo origin, verifies
its echo byte-for-byte, then sends opaque payload. It measures passthrough without
TLS crypto or application semantics. Complement this with real encrypted traffic
when evaluating a deployment. The origin is not a TLS endpoint or an HTTP server.

Prefer separate generator, proxy and origin hosts with known NIC limits. Loopback
is useful for correctness and early profiling but shares CPU/kernel work with the
proxy and cannot establish a network throughput ceiling. Pin the proxy to a CPU,
put generator/origin elsewhere, and record kernel, CPU governor, affinity, NIC,
socket defaults, configuration and binary commit/build mode. Match these settings
when comparing configurations and builds.

Start the origin, launch the proxy, then run the generator in separate terminals:

```sh
ulimit -n 8192
python3 bench/harness.py serve --host 127.0.0.1 --port 9443
```

```sh
ulimit -n 8192
taskset -c 2 zig-out/bin/zigveil bench/zigveil.json
```

Adjust the numeric endpoints for a separate-host topology. Disable packet/access
logging and keep the same process count across runs.

## Streaming, latency and connection churn

```sh
python3 bench/harness.py run --mode bulk --duration 30 --concurrency 1
python3 bench/harness.py run --mode bulk --duration 30 --concurrency 10
python3 bench/harness.py run --mode bulk --duration 30 --concurrency 100
python3 bench/harness.py run --mode bulk --duration 30 --concurrency 1000
python3 bench/harness.py run --mode latency --duration 30 --concurrency 100
python3 bench/harness.py run --mode churn --duration 30 --concurrency 16
```

Bulk and latency establish all streams before the timed region. Setup is paced
through 16 concurrent handshakes to avoid mistaking an artificial accept burst for
long-lived capacity. Bulk sends/receives simultaneously, then half-closes and drains
with byte-count validation. The bulk sender also limits unreturned echo payload to
`--inflight-bytes` per stream (default 262144 bytes, 256 KiB). Socket write-buffer
backpressure alone cannot bound the total queued echo across both TCP legs. With
1000 streams the default application credit bound is 250 MiB in total; this is a
bound on unreturned payload, not an RSS or kernel-memory measurement. Keep the same
window across comparisons; a small window can limit goodput on a high-RTT path.
The window must be at least `--chunk-bytes`, and is recorded with the observed peak.

Tail drain time is included in measured `seconds` and reported as `drain_seconds`.
`--drain-timeout` allows 15 additional seconds by default after the payload window.
For a deliberately delayed origin, set it explicitly:

```sh
python3 bench/harness.py run --mode bulk --duration 30 --concurrency 1000 \
  --inflight-bytes 262144 --drain-timeout 30
```

Timeouts and stream failures produce JSON with `valid: false`, nonempty `errors`,
partial byte/cycle counts and a nonzero exit code. Rates and latency percentiles
are `null` for a failed run. `unfinished_workers` identifies timeout cancellations;
the raw byte totals then describe generator progress, not a complete forwarded run.
Error strings are deduplicated and capped at 16, with one additional timeout summary;
`error_count` retains the affected worker count. Cleanup aborts failed streams and
bounds graceful close waits so a stalled peer cannot trap cancellation.

`echo_goodput_gbit_s` counts echoed receive bytes once; `aggregate_forwarded_gbit_s`
counts both forwarded directions. Use a consistent denominator across experiments.

Latency is 64-byte echo RTT, including network and origin work. Reservoir sampling
is bounded to one million samples across streams; p50/p99 come from those samples.
This is not one-way forwarding latency. Run a direct-origin control under the same
topology to estimate proxy overhead; report both distributions and mark the
difference as an estimate. Churn measures completed TCP connect + hello echo + close
cycles/s, not raw SYN acceptance.

Keep the JSON output as raw evidence. Use 5+ repetitions, a warm system and randomized
or alternating experiment order. Keep failures visible. Raise generator fd limits
for high concurrency. Repeat bulk with 4/16/32/64 KiB rings using separate JSON
fixtures and compare CPU and memory. Hold all other settings constant.

## GitHub Actions

Open **Actions → Benchmarks → Run workflow**, select the revision, and set
`duration` (seconds per workload, default 10) and `repeats` (default 3).
Use 30 seconds and at least 5 repetitions for comparisons when runner capacity
and time permit. Native Ubuntu 26.04 amd64/arm64 jobs build ReleaseFast and run
bulk at 1/10/100/1000 streams, latency at 100 and churn at 16. Every case also runs
a direct-origin control. Direct/proxy order alternates between repetitions.

Each job has a summary with medians and passed/requested counts. A failed or
missing repetition suppresses that case's median and fails the job. The artifact
contains every raw result, failures, the exact config, child logs and metadata
for the commit/build, kernel, CPU, affinity, Python, socket defaults and cgroup
limits. `bench/ci.py` starts separate local origin/proxy/generator processes and
owns their cleanup. It does not tune CPU or kernel settings.

Hosted runners share physical resources and all three workload processes use
loopback on one runner. Their results support comparisons under the recorded
conditions; they do not establish a deployment's maximum throughput. Use a
dedicated runner and a controlled multi-host topology for that measurement.

The ordinary Linux CI additionally runs `test/bench_harness.py` for bounded
echo credit, delayed FIN, structured timeout/early-EOF failures, CLI exit status,
cancellation cleanup and 1000 streams through the production proxy. These are
correctness regressions with no throughput threshold.

## CPU, RSS, context switches, cycles and syscalls

Capture counters around the same timed window. Supply every proxy process PID;
`/proc` sampling requires no third-party Python packages:

```sh
python3 bench/collect.py --pid "$PID" --duration 30 --active-connections 1000
```

JSON includes user+system CPU seconds, context switches, RSS/virtual bytes, peak
sampled RSS, threads and fds. Kernel socket memory is outside RSS. Record an idle
baseline and retained capacity as well as active RSS; fixed slabs make
`RSS / active connections` different from marginal connection cost.

On a host with perf available and authorized:

```sh
perf stat -p "$PID" -e cycles,instructions,context-switches -- sleep 30
perf stat -p "$PID" -e 'syscalls:sys_enter_*' -- sleep 30
```

Hardware counters and tracepoints depend on kernel support and permission. Sum all
relevant processes/threads and account for idle/startup overhead. A strace summary
can diagnose syscall mix, but its overhead makes it a separate diagnostic run;
compare throughput only between runs with equivalent instrumentation.

Given the same window's actual forwarded byte total, `--forwarded-bytes`, `--cycles`
and `--syscalls` make collect.py compute:

```text
CPU seconds / Gbit = CPU_seconds / (forwarded_bytes × 8 / 1e9)
cycles / byte = cycles / forwarded_bytes
syscalls / GiB = syscalls / (forwarded_bytes / 2^30)
```

These counters are measured inputs. Report single-stream/aggregate throughput,
errors, CPU/Gbit, cycles/byte, RSS/active connection, completed connection cycles/s,
RTT p50/p99, syscalls/GiB and context switches at 1/10/100/1000 streams. Retain all
configs and raw outputs. The scripts do not install software or tune the host.

## Stress and soak

Run correctness tests first. On a dedicated host keep 1000 streams active for
30+ minutes, alternate bulk/idle/churn, reset peers and restart origins. Sample
counters, fds and memory throughout and after drain. Provide adequate connection,
staging and fd capacity. Check zero corruption, eventual resource reclamation,
bounded retained RSS, no idle spin and controlled expiry/admission. Synthetic echo
is a baseline; actual client traffic requires its own versioned evidence.
