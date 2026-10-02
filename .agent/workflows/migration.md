---
description: Controlled binary/config or host migration for static TLS passthrough routes.
---

# Migration workflow

1. Preserve the current binary, commit identity and configuration for rollback.
2. Verify the new binary's CI, supported Zig version and resource contract.
3. Validate the new config with `--check`; test each backend using the real client
   protocol and inspect aggregate counters on the new listener.
4. For host migration, route clients to the new IP only after it passes those checks.
   For in-place upgrades, replace the service binary/config and restart explicitly.
5. Account for long-lived tunnels: stop accepts and allow the existing process's
   bounded drain. Established TCP sessions cannot migrate between processes or hosts.
6. Confirm new traffic, descriptor reclamation and no unexpected parser/timeout
   rejection before retiring the old service. Restore the saved binary/config and
   client destination if verification fails.

There is no config hot reload, connection handoff, dynamic discovery or automatic
DNS update. A second SIGTERM/SIGINT forces the remaining connections to close;
systemd's stop timeout must exceed the 30-second daemon drain window.
