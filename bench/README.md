# Relay benchmarks

The tools here are optional. Zigveil has no benchmark runtime dependencies.
The workload is a synthetic ClientHello followed by opaque TCP echo data.
Every payload byte is checked against a deterministic pattern; TLS cryptography
and application processing are outside this measurement.

## Paired measurements

The manual **Benchmarks** workflow uses exactly Zig 0.17.0 on native Ubuntu 26.04
runners. By default it measures the ordinary candidate and a direct-origin control.
An explicitly supplied baseline is built on the same runner with the same compiler
and uses the candidate's harness. The coordinator rotates variant
order between repetitions, reverses the ring sweep, and retains every trial,
including failures. amd64 and arm64 results are separate.

```sh
gh workflow run benchmarks.yml \
  -f baseline=BASELINE_COMMIT -f duration=30 -f repeats=3 \
  -f workloads=bulk:1,bulk:10,bulk:100,bulk:1000,latency:1,loaded-latency:100,churn:16 \
  -f rings=16384,32768,65536 -f profiling=basic -f architecture=both
```

Use 10 seconds × 3 repetitions for discovery and 30 seconds × 3 for confirmation.
The ten inputs are duration, repeats, baseline, workloads, rings, profiling,
processes, instrumentation, architecture and optional JSON options.
Empty `baseline` omits that build. `instrumentation=false` omits the diagnostic
binary; both are the defaults. Profiling defaults to `basic`; `perf-stat` and
`perf-record` are explicit diagnostic choices. For a code comparison, supply the
full production commit immediately before the change. That revision must support
Zig 0.17.0. Match baseline/candidate configuration to isolate the code change.

| JSON option | Default | Purpose |
| --- | --- | --- |
| `chunk_bytes` | 65536 | Send chunk, 256..1048576, a multiple of 256 |
| `inflight_bytes` | 262144 | Unreturned echo bytes per stream; at least one chunk |
| `warmup` | 1 | Established-stream warmup seconds, 0..30 |
| `warmup_bytes` | workload message size | Python warmup override, 1..1048576; exercise large-to-small traffic transitions |
| `drain_timeout` | 15 | Additional drain deadline, greater than zero and at most 120 seconds |
| `variants` | provided binaries plus `direct` | Distinct subset of `direct`, `baseline`, `candidate`, `metrics` |
| `generator`, `origin` | `native` in Actions | Select `native` or `python` independently |
| `generator_workers` | 1 | One or two independently pinned bulk generators, sharing the requested stream count |
| `origin_io` | `buffered` | Native echo via its reference queue or a single shared `splice` pipe with bounded queue fallback |
| `baseline_ring` | candidate ring | Explicit old ring for comparing default configurations |
| `baseline_processes` | candidate process count | Paired scale-out with identical baseline/candidate code |
| `cpu` | `baseline` | Candidate code generation: `baseline`, `native`, or `x86_64_v3` on amd64 |
| `relay_splice` | true | Production splice path; false provides a buffered control |
| `baseline_splice` | baseline build default | Explicit splice build option for comparisons with a revision supporting it |

For example, `-f 'options={"variants":["baseline","candidate"],"baseline_ring":16384}'`
compares the requested candidate ring against a 16 KiB baseline. The summary
shows both configured sizes. Match rings to isolate code changes; different
sizes measure the combined code/configuration change.

Use `processes=2` for independent `SO_REUSEPORT` proxies. Each proxy, generator
and origin needs a distinct logical CPU. Four proxies need at least six available CPUs.
Insufficient capacity is recorded as an unavailable scaling experiment.
Pass `--require-workloads` to `bench/ci.py` when execution is mandatory: unavailable
CPU topology then exits nonzero. Linux CI uses this flag and one generator for its
shared-splice correctness workloads, including 1000 connections. Optional manual
scale-out experiments retain the unavailable result when their topology cannot run.
For a paired 1→2 process comparison, build the same revision on both sides,
select `processes=2` and `options={"baseline_processes":1}`. Generator/origin keep
the same CPUs across both variants; the summary reports scaling efficiency.
Metadata records guest-visible core IDs and SMT sibling lists. Raw trials list
actors sharing a visible core; distinct vCPUs alone do not establish physical
core isolation, and the hypervisor's underlying host topology can remain unknown.

## Window and workloads

Each trial owns separate proxy, origin and generator processes and records their
affinity. Direct controls keep origin/generator on the same CPUs as proxy trials.
`loaded-latency` uses an independent Python 64-byte RTT probe alongside bulk;
a spare core isolates the probe when available. With two generators on four
cores it shares the origin CPU; `probe_has_distinct_cpu=false` records this.
Use one generator for isolated tail-latency confirmation. Resources are sampled
at 10 Hz. Native origin startup reports its actual I/O mode and any pipe fallback.

Bulk/latency streams establish and warm up before a ready/go barrier. The
latency probe uses 64-byte warmup messages, bulk uses 64 KiB. Multi-generator
rates use the common earliest-start/latest-end window, not summed individual rates.
The coordinator captures counters and `/proc`, enables optional perf, then starts
timed payload. End snapshots precede authorization of FIN and tail drain.
Setup and teardown are excluded from steady-state CPU metrics. Boundary times
and skew are retained. Churn includes connect, ClientHello echo and close.

Bulk sends and receives concurrently with bounded credit. At 1000 streams,
256 KiB per stream allows 250 MiB unreturned payload. This is a workload bound,
not RSS or kernel memory. Keep chunk and credit identical across variants and
check sensitivity to both. A small window can limit a high-RTT path.

For a single-core bulk ceiling, use `options={"generator_workers":2,"origin_io":"splice"}`
on a runner with four available cores. This reduces reference-generator/origin
CPU pressure; their individual utilization still determines whether a proxy
ceiling was observed. For isolated latency under load, use one generator with
`options={"origin_io":"splice"}` so the RTT probe has the fourth core.

`echo_goodput_gbit_s` counts returned payload once; `aggregate_forwarded_gbit_s`
counts both directions. Their denominator includes final echo drain, separately
reported as `drain_seconds`. CPU/cycles use the steady window's actual proxy
forwarded-byte counters. Both denominators are explicit. Corruption, timeout,
stream failure, unexpected proxy errors or unreclaimed fds fail the trial.
Failed rates are `null`; all owned child cleanup has deadlines.
The Python generator also reports setup/warmup failures as JSON with a nonzero
exit status and null rates. Warmup workers are cancelled and joined before their
streams close; no measurement starts after failed warmup.
After drain, an ordinary proxy retains six base fds, or ten after lazy shared-pipe
allocation. An explicitly buffered variant must retain six. Inspect socket-pressure
records and generator/origin CPU when a trial fails; failures remain in the output
and do not produce a throughput claim.

Latency reports sample count, p50/p90/p95/p99, max, mean and standard deviation.
p99.9 requires 10,000 retained samples; the reservoir holds at most one million.
RTT includes origin and loopback/network work. Subtracting a direct-control
percentile estimates added latency, not one-way forwarding latency.

The job summary shows passed/requested trials, medians, CV, paired percentage
changes and bootstrap 95% intervals for throughput, CPU/Gbit, cycles/byte,
instructions/byte, syscalls/GiB, latency and RSS. Metrics-vs-ordinary comparisons
show the observer effect. JSON retains min/max, MAD, all pairs, actor resources,
configuration and environment. Incomplete groups have no median or speed claim.
An interval excluding zero describes these pairs, not another host.

## CPU and profiling

`/proc` captures user/system CPU, total scheduled CPU, utilization per core,
CPU seconds per forwarded Gbit, context switches, faults, migrations, runqueue
time, RSS, sampled/lifetime peaks, virtual memory, threads and fds. Generator,
origin and RTT probe have separate records. Socket/pipe kernel memory is outside
RSS. Check actor saturation before declaring a proxy ceiling.

`perf-stat` probes hardware/software events and each syscall tracepoint. It tries
current privileges, then noninteractive sudo when available. Absent tools,
permissions or unsupported events produce `available=false` with a reason.
Kernel settings are unchanged. Supported events are gated to the measured window;
raw output and event running percentages retain multiplexing information.
Derivatives include cycles/instructions per byte and Gbit, IPC and syscalls/GiB.

`perf-record` adds a separate diagnostic bulk trial, excluded from speed statistics.
Artifacts include `perf.data`, leaf hot symbols, recorded call graphs and a
sampled kernel/user/unknown split. Sampling and syscall tracepoints can affect
throughput. Use `basic` and ordinary fast for final speed claims, and
matched profiling settings for diagnostic comparisons.

`-Ddataplane_metrics=true` compiles plain single-owner diagnostic counters.
The production default is false, with zero counter storage and erased increments.
Only that build adds a `dataplane` JSON snapshot to SIGUSR1. It covers actual I/O,
EAGAIN/EINTR, partial writes, queue/pump exits, readiness batches and control
syscalls. It adds no per-packet timestamps,
allocations, atomics or logs. Counter deltas refer to the window; size/batch
maxima are lifetime gauges including warmup. Runtime stats stay separate.

Metadata records both revisions, compiler/build/options, CPU model/count/affinity,
kernel, visible frequency/governor, NUMA, cgroup quota/cpuset/memory limits, fd
limits, TCP/pipe sysctls, parameters and perf capabilities. Unavailable values
are `null`. Artifacts include child logs, configurations and before/after resources.
Both candidate and optional baseline use exact Zig 0.17.0 with `-Doptimize=fast`.
Metadata records
`candidate_zig_version`, `baseline_zig_version` and each build mode; the job also
verifies the installed compiler and prints the build settings. Keep CPU, rings,
splice, processes and workload parameters matched for a revision comparison.

## Running on Linux

Build the optional native generator/echo origin alongside the daemon:

```sh
zig build -Doptimize=fast -Dbench_tools=true --prefix /tmp/zigveil-candidate
zig build -Doptimize=fast -Ddataplane_metrics=true --prefix /tmp/zigveil-metrics
python3 bench/ci.py --binary /tmp/zigveil-candidate/bin/zigveil \
  --metrics-binary /tmp/zigveil-metrics/bin/zigveil \
  --native-binary /tmp/zigveil-candidate/bin/zigveil-bench \
  --duration 30 --repeats 3 --profiling basic --output /tmp/zigveil-results
```

Libc is used only by the optional native benchmark tool. It supports bulk and a
bounded epoll echo origin. Python remains the latency/churn reference and can
also generate bulk or serve the origin. CI checks native/Python interoperability,
corruption, timeouts, 1000 streams, barriers and resource reclamation.

For manual or separate-host measurements, the reference CLI remains available:

```sh
ulimit -n 8192
python3 bench/harness.py serve --host 127.0.0.1 --port 9443
taskset -c 2 zig-out/bin/zigveil bench/zigveil.json
python3 bench/harness.py run --mode bulk --duration 30 --concurrency 1000
python3 bench/harness.py run --mode latency --duration 30 --concurrency 100
python3 bench/harness.py run --mode churn --duration 30 --concurrency 16
```

Use separate terminals and adjust endpoints for another topology. Complement
measurements on a dedicated host with prolonged bulk/idle/churn, slow receivers,
resets and restarts. Verify exact bytes, independent half-closes, fd reclamation
and bounded retained memory. Shared-runner loopback measures the recorded
CPU/kernel workload; known-NIC multi-host tests and actual client traffic are
needed to establish a deployment ceiling.
