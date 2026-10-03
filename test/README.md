# Verification

`zig build test` imports parser, name, config, buffer, pool, timers, connection and
Linux syscall-boundary tests.
The artificial socket implementation drives **the production Connection engine**;
it substitutes recv/send/connect/shutdown operations, not state transitions.

| Contract | Coverage |
| --- | --- |
| Complete/partial ClientHello | Every TCP prefix, single-byte deliveries, split record headers/fields |
| Record fragmentation | Multi-record valid input, split SNI, excessive record count |
| Input rejection | Record/handshake/vector lengths, duplicate SNI, malformed tail/name, over-limit input |
| Bounds | Maximum 65536-byte wire prefix and larger hostile input |
| Routing | Case folding, exact/unknown/missing names, fallback and no fallback on invalid input |
| Hostname backends | Mandatory port, URLs rejected, startup resolution, IPv4 preference/IPv6-only selection, failure cleanup and resolved self-target validation |
| Self targets | Exact/wildcard-loopback and mapped aliases in routes/fallback; other ports, remote peers and V6ONLY family independence |
| Accept errors | Production raw-result decoder: interrupted, empty, per-connection, resource-pressure and fatal outcomes |
| Preservation | Hello plus coalesced tail, maximum prefix sent through small relay rings |
| Partial I/O and pressure | Short sends in both directions, full ring suppressing source reads, resume |
| EOF and FIN | Both half-close orders, drain before FIN/ENOTCONN, opposite buffered data, no repeated shutdown |
| Failures | Connect/read/write failures, fatal shutdown and ENOTCONN with pending reset on both peers |
| Error dimensions | Exact errno through production read/write/shutdown/SO_ERROR paths; both socket roles, unknown errno, zero writes, aggregate consistency and no double count |
| Stats bounds | Maximum-width u64 values produce complete JSON within the fixed 4096-byte buffer |
| Logging | Severity filtering, one-second delta batching, idle suppression, control/JSON escaping, maximum-width totals and byte units |
| Shared kernel queues | Exact prefix ordering, empty borrow/return, slow writes and ring spills, uneven reads at fairness boundaries, source EAGAIN and page pressure, both FIN orders, RST/EPIPE/ENOTCONN, allocation failure, reuse and small/large phase transitions |
| Time | Hello/connect/prefix/idle expiry and disabled established idle |
| Lifetime | Pool exhaustion, role/generation tokens and stale events after reuse |
| Timers | Indexed insertion/update/cancellation/reuse against an independent randomized model |

`zig build fuzz -Doptimize=ReleaseSafe` runs seeded random input, structured field
mutations and maximum-size parser cases. `fuzz.check(bytes)` is a pure test entry
point suitable for an additional coverage-guided harness. This target is a bounded
mutation regression campaign; it is not a claim of exhaustive fuzz coverage.

The Python Linux suite starts actual daemon processes and loopback origins. It
checks raw-prefix preservation, fragmentation, simultaneous bulk streams, slow
consumers, both FIN orders, unknown/missing/invalid routing, fallback, timeout and
admission recovery, connect refusal, reset churn, fd reclamation, actual fd-quota
backoff without spinning through repeated recovery with an established stream,
self-target config rejection before bind, V6ONLY forwarding to IPv4/mapped backends
on the listener port, a single OS thread and
real TLS passthrough through an IPv6 backend. Certificates are generated temporarily
by OpenSSL. It does not require third-party Python packages.

Live logging tests check compact text, explicit grouped totals, warning bursts,
info/warn/error/none filtering, the SIGUSR2 cycle, snapshots while muted and precise
debug RST details without payload leakage or changes to error accounting. Invalid
logging settings fail before bind. Readiness checks an owned socket without probe
traffic and works independently of INFO output.

Controlled client and backend RST tests use zero SO_LINGER after an echoed prefix.
The daemon is stopped temporarily with SIGSTOP while RST is queued, then resumed:
the existing EPOLLERR probe deterministically reports ECONNRESET on the correct
socket side. Each test checks exact operation/cause dimensions and both aggregate
sums. Both FIN orders and full-duplex bulk additionally require zero I/O errors
after clean drain. EPIPE is checked through the production engine for both send
destinations and a real Linux socketpair after local SHUT_WR. A daemon-level EPIPE
race is not asserted: its existing error probe can consume reset before send.

```sh
python3 test/integration.py --binary zig-out/bin/zigveil
```

The CI runs builds and unit tests in Debug, ReleaseSafe and ReleaseFast, socket
tests in Debug and ReleaseFast, parser mutations in ReleaseSafe, a smoke test of
the benchmark workload, and focused harness regressions.
`test/bench_harness.py` checks bounded unreturned echo credit, delayed drain, failed
measurement JSON and exit status, cancellation/close cleanup, and 1000 real streams
through ReleaseFast Zigveil with clean byte counts, FIN and I/O counters:

```sh
ulimit -n 8192
python3 test/bench_harness.py --binary zig-out/bin/zigveil
```

The manually dispatched Benchmarks workflow records actual workloads and direct
controls; see [the benchmark guide](../bench/README.md#paired-measurements).
Timing bounds in integration
tests allow event-batch delays and runner scheduling; throughput assertions and
performance numbers are intentionally absent. Production-host soak, real client
captures and controlled comparative benchmarks remain separate verification work.

`test/dns_integration.py` exercises actual DNS in a disposable root-capable Linux
environment. A private mount namespace supplies controlled hosts/resolver files
without modifying the runner's files. The local UDP fixture supplies A/AAAA, many
answers, IPv6-only, NXDOMAIN and self-target cases. Tests require unchanged routes
after a DNS answer changes, more hosts results than fit in the fixed queue, exact
stream bytes, clean FIN and a single serving thread after resolver teardown.
No external DNS service is required. CI runs this suite in both build modes on
both architectures. The ordinary integration suite also checks localhost routes
and fallback.

```sh
sudo python3 test/dns_integration.py --binary zig-out/bin/zigveil
```

CI additionally builds native amd64/arm64 Docker images and checks the entrypoint,
read-only configuration, byte preservation, bulk, FIN and container shutdown.
The installer E2E uses an ephemeral local registry and systemd host to verify first
install, actual traffic, refusal of insufficient fd capacity without disturbing a
running service, config preservation and a real container update.
The update also verifies log_level none, socket-based readiness and visible explicit
preflight failures without depending on a startup banner.

The optional `-Ddataplane_metrics=true` build has separate engine and real-socket
coverage. `test/bench_lab.py` checks paired statistics, coordinated measurement
windows, native/Python interoperability, two generators, exact bulk echo,
under-load probes, ordinary baseline comparisons without diagnostics, and child/fd
cleanup. CI checks the shared splice default and
the `-Drelay_splice=false` buffered control. Diagnostic counters compile out of
ordinary builds and keep the production stats schema intact.
