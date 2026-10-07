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
major tags. Preserve digest validation and the publish gate for every requested build.
Before any registry build/upload, call the full reusable Linux CI workflow from
the publication commit. A green run for another commit is not sufficient. Keep
CI concurrency groups distinct by entry workflow so publication validation cannot
cancel standalone Linux CI, or be cancelled by it.

The installer is `deploy/install_docker_compose.sh`. First install needs a full
CONFIG_SOURCE or explicit SNI/BACKEND. Existing JSON is retained on updates. Pull,
Compose validation and an image-based --check finish before stopping/recreating
the existing service. Never make an invalid config or failed pull disrupt it.
Keep the installation-directory lock, stdin-only registry password handling,
read-only mounts, fd limits and graceful-stop interval. The entrypoint must never activate example
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
Compose reload recreates the container. It permits an interruption of new accepts
while the old process drains (up to 30 seconds) and the replacement starts. Existing
connections that outlive the drain deadline close. Preserve this simple update
contract and describe the interruption when changing deployment instructions.
Readiness inspects a LISTEN socket owned by the container PID, so warn/error/none
verbosity works too. Do not restore a startup-log dependency. --check is an explicit
diagnostic and reports failure even when automatic daemon logs are disabled.

## Native systemd deployment

1. Prepare the Linux service host and dedicated `zigveil` user/group.
2. Copy the binary to `/usr/local/bin/zigveil` and a validated operator config to
   `/etc/zigveil/config.json`. Replace documentation-only endpoint addresses.
3. Ensure the descriptor limit covers `2 × max_connections + 12`. The supplied unit
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
For process scale-out, manage multiple independent units with identical routes and
`reuse_port: true`; count resource limits and metrics per process. Do not introduce
an in-process worker manager just to match host core count.
