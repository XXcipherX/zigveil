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
with byte-count validation. Tail drain time is included in measured seconds.
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
