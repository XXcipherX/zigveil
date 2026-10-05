---
description: Diagnose routing, pressure, timeout and relay failures with bounded aggregate data.
---

# Diagnostics workflow

Validate configuration and descriptor budget first:

```sh
zigveil --check /etc/zigveil/config.json
systemctl status zigveil --no-pager
journalctl -u zigveil -n 100 --no-pager
journalctl -u zigveil -f
kill -USR1 "$PID"
kill -USR2 "$PID"
```

Use an explicit PID for each process. Default info/text logs show lifecycle events,
compact interval activity and live warning/error groups. Idle/zero fields are quiet.
SIGUSR1 requests cumulative grouped totals, or complete JSON with log_format json,
even at log_level none. SIGUSR2 cycles info/debug/none/error/warn and confirms the
change; restart restores config verbosity. debug shows connection IDs, phase/close
reasons and exact fatal socket metadata, without payloads or client IPs. Changing
verbosity does not reset counters or replay previously muted failures.
No packet logging or admin listener is available.

Hostname backends resolve once during startup and `--check`, using the environment's
hosts/resolver files. Resolution errors prevent listening; a DNS change requires a
restart. The selected IPv4 (otherwise IPv6) still undergoes self-target checks.

| Counter | Investigate |
| --- | --- |
| `unknown_sni` / `missing_sni` | Client's visible name and configured route/fallback |
| `routed` / `fallback_routed` | All selected endpoints / fallback subset; selection precedes connect |
| `invalid_client_hello` | Framing/name/inspection failure or partial EOF, including successfully forwarded fallback input |
| `connect_failures` | Selected target IP, routing/firewall and backend listener |
| `rejected` | Connection/staging capacity, descriptor resources or unsupported PROXY socket metadata |
| `accept_errors` | Pending connection errors or fd/memory pressure; only resource pressure backs off |
| `timeouts` | Absolute hello/connect/prefix or established idle deadline |
| `io_errors` | Aggregate fatal socket outcomes; inspect side/operation and cause below |
| forwarded bytes | Successful original-stream sends including the hello; generated PROXY header is excluded |

Partial hello expiry can select fallback and still increments timeouts; empty
expiry closes. Classifier counters are observations, not necessarily drops. Debug
proxy_metadata_failed identifies unsupported endpoint metadata. Actual PROXY
address-query errors retain client_socket_errors and their exact errno cause;
they do not log addresses or header contents. Known-SNI backend failure never
reroutes to fallback. Verify that a PP-enabled backend consumes the preamble before
TLS/data when debugging immediate backend disconnects.

For `io_errors`, use the [README counter tables](../../README.md#clienthello-and-security-limits).
`client_*` / `backend_*` name the actual socket: a forward send is a backend write,
not a client write. `*_socket_errors` is a failed SO_ERROR probe, its pending errno,
or a failed client peer/local endpoint query for PROXY v2; it is not proof that
recv/send failed. Each event increments one
operation and one cause, so sum each dimension separately against `io_errors`.
`last_other_io_errno` records only the most recent unclassified numeric errno and
must not be summed. `socket_timeouts` (ETIMEDOUT) differ from proxy deadlines.
Clean FIN and retry outcomes remain uncounted; ECONNRESET/EPIPE stay fatal observed
socket outcomes. They appear in info summaries/debug closes instead of one warning
per teardown. Other live failures are grouped at most once per severity per second,
independent of stats_interval_ms. Use a controlled reproduction and workload evidence to decide
whether these outcomes are expected; the snapshot cannot reconstruct old runs.

`FatalListenerError` exits the process instead of repeatedly resuming an invalid
or policy-denied listener. Check stderr and listener ownership/OS policy.

Check `/proc/$PID/fd`, `/proc/$PID/status` and OS TCP memory alongside counters.
Reserved buffer bytes, RSS and kernel socket memory measure different resources.
Four additional idle fds may belong to the process's shared relay pipes after
bulk traffic. They must stay constant across connection churn; no connection may
retain bytes in them after its callback. Instrumented SIGUSR1 snapshots distinguish
splice traffic, ring spills, activation/fallback and the shared pipe capacity.
Read/write dimensions cover both buffered socket operations and splice. Reclaim
failures count on that direction's source and disable the shared pipes; allocation
failure uses the buffered fallback and is visible in optional dataplane counters.
Capacity sums across SO_REUSEPORT processes. A staging shortage may occur while
established relays still have connection capacity; inspect slow hello/connect/prefix
progress rather than increasing every pool blindly.

For forwarding bugs, run the Linux integration suite, reproduce both FIN orders,
and compare byte streams at the controlled origin. For CPU or throughput concerns,
use bench/collect.py plus a controlled harness and optional perf. High generator or
origin CPU can make a proxy appear saturated when it is not. Keep payload contents
out of normal diagnostics.
