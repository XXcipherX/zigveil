# Zigveil

[![Linux CI](https://github.com/XXcipherX/zigveil/actions/workflows/ci.yml/badge.svg)](https://github.com/XXcipherX/zigveil/actions/workflows/ci.yml)
[![Zig 0.16.0](https://img.shields.io/badge/Zig-0.16.0-f7a41d)](https://ziglang.org/download/0.16.0/release-notes.html)
[![MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

A small Linux TCP passthrough proxy in Zig. Zigveil inspects the first TLS
ClientHello, selects a fixed backend by SNI, then relays both byte streams unchanged.
It is designed for long-lived encrypted tunnels, continuous downloads and opaque
TCP-over-TLS services.

```text
client ── TCP :443 ── Zigveil ── TCP ── selected backend
                      │
                 ClientHello → exact SNI lookup
                 all received bytes → backend unchanged
```

TLS stays between the client and backend. Zigveil has no certificates or private
keys, does not terminate or decrypt TLS, and does not inspect application traffic.
The incoming stream must begin with a compatible TLS ClientHello; after routing,
the backend protocol is opaque.

## Scope

- IPv4/IPv6 or hostname backends, exact ASCII SNI names and an optional fallback.
- One serving thread and one level-triggered epoll loop per process.
- Startup-reserved pools and fixed rings; no serving-path heap allocation.
- Partial I/O, bounded backpressure, independent EOF/FIN in both directions.
- Absolute hello/connect/prefix deadlines and optional relay idle timeout.
- Readable live logs, configurable levels and optional JSON counter snapshots.
- Standard library only; no third-party Zig dependencies or libc requirement.

There is no HTTP handling, TLS termination, DNS refresh while serving, routing reload, regex,
load balancing, protocol transformation or QUIC/UDP support. Backend TCP peers see
the proxy's IP address; the proxy does not prepend a PROXY protocol header.

## Build and test

Use **Zig 0.16.0**. Supported targets are Linux x86_64 and aarch64.

```sh
git clone https://github.com/XXcipherX/zigveil.git
cd zigveil
zig build -Doptimize=ReleaseFast
zig build test
zig build fuzz -Doptimize=ReleaseSafe
python3 test/integration.py --binary zig-out/bin/zigveil
```

`zig build` also supports Debug and ReleaseSafe. An explicit target can be supplied
with `-Dtarget=x86_64-linux`. The build rejects other operating systems and Zig
versions. No package manifest is needed because the build has no dependencies.
Integration tests use Python 3 and OpenSSL; neither is required by the daemon.

GitHub Actions verifies formatting, builds Debug, ReleaseSafe and ReleaseFast, runs
deterministic unit tests in all three modes, runs parser mutations with safety
checks, exercises real Linux sockets in Debug and ReleaseFast, and smoke-tests the benchmark tools on native amd64
and arm64 runners. It also builds and exercises both Docker images and verifies
the Compose installer/update flow. Zig is fetched from its official release with
a pinned SHA-256 checksum.

The manual **Benchmarks** workflow measures bulk, latency and connection churn
with direct-origin controls on native amd64/arm64 runners. Results and environment
metadata are saved as artifacts; see the [benchmark guide](bench/README.md#paired-measurements).

## Configure and run

```json
{
  "listen": "0.0.0.0:443",
  "routes": [
    { "sni": "example.com", "backend": "203.0.113.10:443" },
    { "sni": "example.org", "backend": "203.0.113.20:443" },
    { "sni": "example.net", "backend": "203.0.113.30:443" }
  ]
}
```

The addresses above are documentation examples; replace them with your backends.
Route names match case-insensitively after ASCII lowercasing. Use punycode for
internationalized domains. Wildcards, trailing dots, empty labels, IP literals as
SNI and labels longer than 63 bytes are rejected. Hostnames are at most 253 bytes.
Use `[2001:db8::10]:443` for IPv6 endpoints. Ports are mandatory and nonzero;
backends also accept `backend.example.com:443`. The same formats work for `fallback`.
The listener remains a numeric IP endpoint. Backend names use ASCII DNS labels
or punycode; an optional final dot marks an absolute name. URLs, paths and omitted
ports are rejected.

Hostnames are resolved once during startup, including `--check`, using `/etc/hosts`
and `/etc/resolv.conf`. The first IPv4 result is preferred; if none exists, the
first IPv6 result is selected. Resolution failure prevents startup. The selected
IP undergoes the same unicast and self-target validation as a numeric backend.
Resolution finishes and its worker exits before listening. Serving performs no
DNS lookup, address rotation or retry across alternative addresses; restart to
pick up DNS changes. `--check` verifies resolution and config, not TCP reachability.

```sh
# Default capacity needs at least 2060 fds; keep room for the service environment.
ulimit -n 4096
./zig-out/bin/zigveil --check examples/zigveil.json
./zig-out/bin/zigveil examples/zigveil.json
```

Binding port 443 needs the appropriate OS privilege. The supplied
[systemd unit](deploy/zigveil.service) grants only `CAP_NET_BIND_SERVICE` to a
dedicated user. For an unprivileged smoke deployment, change the listener to 8443.

Configuration is fully validated before listening. Unknown JSON fields, duplicate
canonical route names, invalid endpoints and unreasonable resource limits fail
startup. The config file is capped at 1 MiB. `--check` validates without binding.
Changing configuration requires a restart.

Validation rejects exact listener targets and same-port loopback targets covered
by wildcard listeners: IPv4 `127/8` and IPv6 `::1`. This applies to routes and
fallback, including mapped IPv4 destinations. IPv6 listeners are V6ONLY, so an
IPv4 backend on the same port remains independent. Other local interface addresses,
NAT and indirect routing loops require operator checks; interfaces are not discovered.

| Optional key | Default | Meaning |
| --- | --- | --- |
| `fallback` | `null` | Backend for a valid hello with unknown or absent SNI |
| `max_connections` | `1024` | Total slots per process; range 1..65536 |
| `max_handshakes` | `64` | Staging slots; range 1..max_connections |
| `relay_buffer_bytes` | `65536` | Per direction; powers of two from 4096..65536 |
| `hello_timeout_ms` | `5000` | Absolute pre-routing deadline; range 250..60000 |
| `connect_timeout_ms` | `5000` | Separate absolute connect and prefix-send deadlines |
| `idle_timeout_ms` | `300000` | Successful-I/O idle deadline; `0` disables it |
| `stats_interval_ms` | `30000` | Activity summary interval; `0` disables summaries, while live warnings remain enabled |
| `log_level` | `"info"` | `error`, `warn`, `info`, `debug` or `none` |
| `log_format` | `"text"` | Readable `text` or machine-readable `json` |
| `reuse_port` | `false` | Allow independently launched processes to share the listener |

A malformed or over-limit ClientHello is closed even when fallback is configured.
Without fallback, unknown and missing SNI are closed. Connect failures are closed;
there is no failover to an unrelated route.

## Docker image

The prebuilt image is `ghcr.io/xxcipherx/zigveil:latest`, with `linux/amd64` and
`linux/arm64` platforms. Mount a config; the image's documentation example is
outside the live config path and is never activated automatically.

```sh
docker run --rm --network host --read-only \
  --cap-drop ALL --cap-add NET_BIND_SERVICE --security-opt no-new-privileges:true \
  --ulimit nofile=65536:65536 \
  --mount "type=bind,source=$PWD/config.json,target=/etc/zigveil/config.json,readonly" \
  ghcr.io/xxcipherx/zigveil:latest
```

For local image builds use `docker build -t zigveil .`; select safety checks with
`--build-arg PRODUCTION_MODE=ReleaseSafe`. Both production modes build PIE binaries.
The runtime contains the daemon and a small entrypoint, without a compiler.
`--check`, `--help` and `--version` pass through without creating a config.

Publish with **Actions → Publish Docker image → Run workflow**. The workflow
builds on native Ubuntu 26.04 amd64/arm64 runners, pushes by digest, verifies each
image, then checks runnable platforms before applying tags. Published tags include
the selected tag, optional `latest`, and `sha-<commit>`. An optional amd64 image
uses the `x86_64_v3` CPU profile and receives the corresponding `-amd64-v3` tags.
Generic images use baseline CPUs. Publishing runs are serialized.

## Docker Compose installer

On a Debian/Ubuntu Linux host with systemd:

```sh
curl -fsSL https://raw.githubusercontent.com/XXcipherX/zigveil/main/deploy/install_docker_compose.sh \
  | sudo env SNI=example.com BACKEND=203.0.113.10:443 bash
```

Replace the example name/backend with your route. For multiple routes or custom
limits, supply `CONFIG_SOURCE=/absolute/path/config.json` instead. The installer
creates `/opt/zigveil/config.json`, `compose.yml`, `.env` and a `zigveil.service`
Compose wrapper. It installs Docker Engine and Compose v2 if needed, pulls the
image, validates config and fd capacity, then starts or reloads the service.
An existing config is preserved byte-for-byte on updates; edit it explicitly when
changing routes. A native `zigveil.service` is migrated after preflight succeeds;
its `/etc/zigveil/config.json` is reused when no source was specified.

| Variable | Default | Purpose |
| --- | --- | --- |
| `SNI`, `BACKEND` | required for a generated first config | One exact route to an IP or hostname with port |
| `CONFIG_SOURCE` | unset | Import a full config on first install |
| `LISTEN` | `0.0.0.0:443` | Listener in a generated first config |
| `INSTALL_DIR` | `/opt/zigveil` | Dedicated absolute directory without whitespace |
| `IMAGE` | automatic | Explicit image/tag/digest; disables CPU profile selection |
| `AUTO_IMAGE_CPU_VARIANT` | `true` | Try `latest-amd64-v3` on compatible x86_64 hosts; fall back to `latest` on pull failure |
| `NOFILE_LIMIT` | `65536` | Container descriptor limit; must cover configured capacity |
| `INSTALL_DOCKER` | `true` | Set `false` to require Docker/Compose already installed |
| `GHCR_USER`, `GHCR_TOKEN` | unset | Optional registry login via password stdin |

Compose uses host networking, a read-only root filesystem/config mount, only the
bind-service capability, rotated logs and a 35-second graceful stop. Installing
or updating is serialized by a host lock. Pull/preflight failure keeps the running
service and deployment files intact. Re-run the installer to update the image:

```sh
sudo bash deploy/install_docker_compose.sh
systemctl status zigveil --no-pager
cd /opt/zigveil
sudo docker compose --env-file .env -f compose.yml logs -f
```

## Runtime and memory

The readiness handler performs consecutive nonblocking reads and writes until
EAGAIN, a full ring, EOF or its fairness limit. Each direction gets up to 128
socket operations and 256 KiB of sent data per dispatch. Write readiness is watched
only for queued bytes. A full destination ring suspends the corresponding source
read interest, letting TCP apply backpressure. Empty rings reset their head so the
next read can use one contiguous span.

After an opaque read of at least 16 KiB, the relay can use nonblocking `splice` through two
pipes shared by the serving process. Each callback returns the pipes empty:
blocked or partial output is saved in that connection's bounded ring. The
original prefix stays ordered, and connections never share pending bytes.
After 32 consecutive splice reads smaller than 1 KiB, drained connections return
to buffered forwarding; a later large read can qualify again. Pipe allocation failure
also keeps the buffered path usable. Build with `-Drelay_splice=false` to disable
this path for a controlled comparison.

EOF stops only that read half. Its remaining prefix/ring/pipe bytes are sent before
`shutdown(SHUT_WR)` forwards FIN; the reverse half remains usable. Both finished
halves, a reset, an I/O failure, or a timeout release the slot. Generation-tagged
epoll tokens reject stale batch events when a slot or fd is reused.

An already disconnected write half can finish after its queue drains if no pending
socket error exists. Resets and failed reads/writes still count as I/O failures.

Buffer reservation is:

```text
max_connections × 2 × relay_buffer_bytes
  + max_handshakes × 65536
```

Defaults reserve **132 MiB of buffer address space**: 128 MiB of relay rings and
4 MiB of staging, plus slot/config metadata. Pages are touched on use, so reservation
is not an RSS prediction. Kernel socket buffers and epoll storage are additional.
Buffer reservation above 1 GiB is rejected. A staging slot is returned after the
entire received prefix has been sent, or on teardown; established relays retain
only their two rings. Even with idle expiry disabled, prefix send remains bounded.
The shared pipes add at most twice the configured ring capacity in kernel pipe
storage and four descriptors per process. Startup requires a descriptor limit of
at least `2 × max_connections + 12` (`+ 8` with splice disabled).

The measured 64 KiB default favors sustained throughput. See the
[recorded decisions](docs/DESIGN.md#performance-decisions-and-measured-rejected-ideas).
Smaller rings reduce memory
reservation and transfer sizes. The [benchmark guide](bench/README.md) explains
how to compare sizes and account for CPU, latency and memory together.

One process is the default. When measurements justify more cores, launch independent
processes with `reuse_port: true` and identical route tables, optionally pinning each
to a CPU. Limits and counters are **per process**; they add across processes. There
is no supervisor or dataplane worker-thread manager inside Zigveil.

## Logging

The default is readable text at `info`, written live to stderr with UTC timestamps
and aligned severity labels. Set these optional JSON keys:

```json
"log_level": "info",
"log_format": "text",
"stats_interval_ms": 30000
```

| Level | Output |
| --- | --- |
| `error` | Fatal service errors, unexpected socket errno and zero-byte nonempty writes |
| `warn` | Errors plus connection failures, deadlines, rejected admissions, accept failures, malformed hellos and other network failures |
| `info` | Warnings/errors, startup/shutdown and compact activity summaries |
| `debug` | Info plus connection phase/close events with an ID, reason and exact socket side/operation/errno on fatal I/O |
| `none` | No automatic daemon output |

Periodic text summaries show the current active count and changes since the previous
summary. Byte volumes use B/KiB/MiB/GiB; zero event fields are omitted. An idle process
does not repeat empty summaries. For example:

```text
2026-10-02T12:00:00Z INFO  activity; active=0 accepted=330 routed=329 closed=330 sent=187.4MiB received=724.1MiB connection_resets=66 broken_pipes=6 unknown_sni=1
2026-10-02T12:00:01Z WARN  failures connect_failures=2
```

New warning/error counts are combined into at most one message per severity per
second, independently of the summary interval. Shutdown flushes pending counts.
Resets and broken pipes appear in info summaries and debug close details; they
still close the affected stream and remain in `io_errors`. Their log severity does
not establish which application caused them. Ordinary FIN has no warning. Debug
logs contain lifecycle metadata, never payloads, ClientHello contents or client IPs.

`SIGUSR1` explicitly requests cumulative totals. Text groups related counters and
omits zeros; `json` emits the complete original `event: stats` object, including zero
fields and exact byte counts. In JSON mode, enabled periodic/final stats also retain
that full schema; other events have `time`, `level`, `event` and `message` fields.

`SIGUSR2` changes the running level in a cycle:
`info → debug → none → error → warn → info`. It prints one confirmation even when
entering `none`. A restart restores the config value; re-enabling logs does not
replay previously muted errors. Level changes flush pending output that is enabled
at the old level before switching. Explicit snapshots and CLI inspection commands
remain available at `none`. Other config changes require a restart.

```sh
# Native service: follow output; use the daemon PID for diagnostic signals.
journalctl -u zigveil -f
kill -USR1 "$PID"
kill -USR2 "$PID"

# Supplied Compose deployment.
cd /opt/zigveil
sudo docker compose --env-file .env -f compose.yml logs --follow
sudo docker kill --signal=USR1 zigveil
sudo docker kill --signal=USR2 zigveil
```

## ClientHello and security limits

The allocation-free parser accepts TLS 1.2/1.3 ClientHello across TCP fragments and
multiple handshake records, including fields spanning record boundaries. Its owned
hostname result cannot alias a recycled staging buffer. It validates framing,
length-prefixed vectors and hostname syntax, skips unrelated extensions by length,
and rejects duplicate SNI or malformed extensions even after finding a name.

Each plaintext record is capped at 16 KiB. The inspected wire prefix is capped at
64 KiB and 64 TLS records. These are admission limits, not a maximum legal TLS
ClientHello size. Larger inputs and extreme one-byte record fragmentation are
rejected. Large key shares do not get a special small limit. The parser is a routing
parser, not a complete TLS validator; it does not negotiate ciphers or authenticate
clients. After the first hello is selected, bytes are opaque, including a later
HelloRetryRequest flight. No received prefix byte is stripped or modified.

SNI is client-controlled routing metadata, **not authentication**. Expose only
backends you intend to make reachable, and ensure a backend does not point back to
the proxy. ECH exposes only an outer name; encrypted inner SNI cannot be routed.
No early TLS application bytes are decrypted or treated specially. Monotonic
deadlines are tracked in a bounded indexed queue, with event-batch scheduling delay.
Keepalive and custom socket-buffer tuning are left to OS defaults; `TCP_NODELAY`
is enabled to avoid holding small forwarding writes.

Logs go to stderr. See [Logging](#logging) for levels and explicit snapshots.
Counters include accepted,
active, routed, unknown/missing SNI, invalid hello, connect failures, forwarded bytes,
timeouts, I/O errors, rejected admissions and closes. Forwarded byte counters count
successful sends, including the complete staged wire prefix.

`io_errors` counts fatal socket outcomes once per failed connection. It covers
established streams and preserves the existing count of failed pre-routing client
reads. Every event also increments exactly one side/operation counter and one
cause counter. These are two views of the same events; sum each view separately,
not all the fields together. Connect and accept failures remain separate.

| Side/operation counters | Observed operation on that socket |
| --- | --- |
| `client_read_errors`, `backend_read_errors` | Failed recvfrom or socket-to-pipe splice; a failed pipe reclaim belongs to that direction's source |
| `client_write_errors`, `backend_write_errors` | Failed sendto or pipe-to-socket splice, including original prefix writes |
| `client_shutdown_errors`, `backend_shutdown_errors` | Fatal SHUT_WR result after the queue drains |
| `client_socket_errors`, `backend_socket_errors` | Failed getsockopt(SO_ERROR) or its nonzero pending error, on EPOLLERR or after drained ENOTCONN |

| Cause counter | Linux result |
| --- | --- |
| `connection_resets` | ECONNRESET |
| `broken_pipes` | EPIPE |
| `not_connected` | Fatal ENOTCONN from read/write; drained shutdown with clear SO_ERROR remains uncounted |
| `connection_aborts` | ECONNABORTED |
| `socket_timeouts` | ETIMEDOUT; distinct from the proxy's deadline `timeouts` |
| `network_errors` | ENETRESET, ENETDOWN, ENETUNREACH, EHOSTDOWN, EHOSTUNREACH, ENONET |
| `other_io_errors` | Any other fatal errno |
| `zero_writes` | Zero-byte success from a nonempty send/splice write; no errno is invented |

`last_other_io_errno` is a gauge holding the exact most recent errno counted in
`other_io_errors`, including values unknown to Zig's enum; zero means none observed.
It is excluded from counter sums. The snapshot is bounded and allocation-free.
Connection lifecycle details appear only at `debug`. Clean FIN and EAGAIN/EINTR do not count as errors.
Reset and broken pipe are observed socket outcomes that remain fatal; the counters
do not declare them either proxy defects or harmless application behavior.

`SIGINT`/`SIGTERM`
close the listener and allow up to 30 seconds of draining; a second signal forces
remaining connections to close. Normal stderr delivery must remain available.

## Engineering documentation

- [Architecture and decisions](docs/DESIGN.md)
- [Test coverage and Linux verification](test/README.md)
- [Benchmark tools and methodology](bench/README.md)
- [Agent entry point](AGENTS.md)
- [Agent skills](.agent/skills/architecture/SKILL.md) and [workflows](.agent/workflows/development.md)
- [Contributing](CONTRIBUTING.md)

The design document records the runtime choices and their costs. Performance
claims require controlled measurements with reproducible workloads.

## License

[MIT](LICENSE).
