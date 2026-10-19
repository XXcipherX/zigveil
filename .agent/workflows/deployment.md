---
description: Image publication, configuration preflight and native/Compose deployment for Zigveil.
---

# Deployment workflow

Use a verified fast or safe binary/image from a known commit.
Deployment runs only on an authorized host. The Compose installer can install
Docker on that host; creating or reviewing the script does not authorize running it.

Fallback is the default pre-routing destination, including classification failure
and partial input at EOF/deadline. Expose only an intended backend. Enabling
fallback_proxy_protocol 2 requires a backend listener that consumes PROXY v2
before TLS/data and trusts the proxy. SNI routes stay raw even if they share that
endpoint. Preflight reports fallback/PROXY settings and optional staging headroom;
verify real traffic after configuration changes. Selected backend failures never fail over.

## Image publication and Compose

`Dockerfile` builds native Linux amd64/arm64 images with verified Zig 0.17.0 archives.
Generic images and ordinary builds use baseline CPU requirements. Full Linux CI
also validates amd64 x86_64_v3; keep each production CPU profile in that matrix.
The publish workflow builds by digest on native Ubuntu 26.04 runners, verifies
runtime behavior and runnable platforms, then publishes the selected/latest/SHA
tags. Optional amd64-v3 images require compatible CPU flags. Use current action
major tags.
The production build context excludes dedicated Zig test/fuzz roots and fixtures;
keep them in the checkout and full Linux CI. A fixture-only edit must not invalidate
the production source COPY layer. Build only the default executable in Docker.
The runtime is scratch with a direct daemon ENTRYPOINT. Builder readelf checks
must reject an interpreter or DT_NEEDED and preserve PIE. CMD supplies only the
default config path; native CLI errors handle absent/invalid files. Docker mounts
hosts/resolver files independently of the base image. Keep no shell, NSS, CA or
timezone packages without an actual dependency. Inspect through host tools and
docker logs; --check/help/version must work with a read-only filesystem.
The operator checks successful Linux CI for the source commit before manually
publishing. Publication builds directly; it does not repeat the Linux CI matrix,
query existing runs or wait for their results. Keep the ordinary CI independent.
Import CI and publication Docker caches with matching architecture, CPU profile
and fast/safe mode; cache misses must still permit a normal image build.
Keep digest smoke checks and platform validation before publishing any tags.

The installer is `deploy/install_docker_compose.sh`. First install needs a full
CONFIG_SOURCE or explicit SNI/BACKEND. Existing JSON is retained on updates. Pull,
Compose validation and an image-based --check finish before stopping/recreating
the existing service. Never make an invalid config or failed pull disrupt it.
Keep the installation-directory lock, stdin-only registry password handling,
read-only mounts, fd limits and stop watchdog. The entrypoint must never activate example
routes or create a config as a side effect of --check/help/version.
Validate root ownership and write permissions of the directory and every parent
before creating/opening installation files. Refuse nonregular/symlinked lock files
and open the lock without truncation. A symlink check alone cannot protect a
directory controlled by another user.

Compose uses host networking; loopback backends refer to the host. Hostname lookup
uses the container's hosts/resolver files during preflight and startup; check those
files or configure extra_hosts/dns when host-specific resolution is required. The
generated zigveil.service controls Compose and can replace the native unit after
preflight. Test install/update behavior on an ephemeral systemd host, including
config preservation and a failing preflight that leaves the running container intact.
Compose reload recreates the container. SIGTERM closes its listener and active
connections immediately through ordinary cleanup, then the replacement starts
on the released port. New accepts pause until readiness and existing clients must
reconnect; no zero-downtime guarantee exists. Preserve stop_grace_period=35s and
systemd stop timeouts as emergency watchdogs, not mandatory waits or substitutes
for signal-driven cleanup. Preserve this simple update contract.
Readiness inspects a LISTEN socket owned by the container PID, so warn/error/none
verbosity works too. Do not restore a startup-log dependency. --check is an explicit
diagnostic and reports failure even when automatic daemon logs are disabled.

## Native systemd deployment

1. Prepare the Linux service host and dedicated `zigveil` user/group.
2. Copy the binary to `/usr/local/bin/zigveil` and a validated operator config to
   `/etc/zigveil/config.json`. Replace documentation-only endpoint addresses.
3. Ensure the descriptor limit covers `linux_io.requiredFds(C, N)`: single owner
   `2*C+12`, multiple owners `2*C+8*N+8` (smaller without splice). The supplied unit
   sets 65536; increase it if your configured capacity requires more.
4. Check backend reachability, avoid routes back to the proxy, and run `--check`.
5. Install `deploy/zigveil.service` as `/etc/systemd/system/zigveil.service`, then
   reload systemd and start the unit when deployment is authorized.

```sh
zigveil --check /etc/zigveil/config.json
systemctl daemon-reload
systemctl enable --now zigveil
systemctl status zigveil --no-pager
```

The unit grants CAP_NET_BIND_SERVICE for low ports, restricts address families and
uses journal output. It does not change firewall rules or DNS. IPv6 listeners are
V6ONLY; use the required address family explicitly.

Verify an actual client through each route, byte counters, handshake/connect/idle
behavior and clean shutdown. A config check does not verify backend reachability.
It resolves hostname backends before bind. DNS changes require a restart; no
runtime lookup or TTL refresh happens in the serving loop.
Keep one container/service/process. Explicit `workers: 1..16` creates internal
owners; default 1 preserves old installs. C/H are shared process totals, divided
with remainders. Multi-worker listeners enable reuseport internally. Readiness
still uses socket ownership of the single process, independent of verbosity.
The installer preserves the user's workers value with the rest of the JSON.
Use the existing pull/recreate/restart workflow; no replicas or supervisor.
Check the controller's startup worker count and SIGUSR1 worker_stats after restart.
