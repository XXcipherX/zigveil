---
description: Controlled binary/config or host migration for static TLS passthrough routes.
---

# Service upgrades and host migration

1. Preserve the current binary, commit identity and configuration for rollback.
2. Verify the new binary's CI, exact Zig 0.17.0 version and resource contract.
3. Validate the new config with `--check`; test each backend using the real client
   protocol and inspect aggregate counters on the new listener.
4. For host migration, route clients to the new IP only after it passes those checks.
   For in-place upgrades, replace the service binary/config and restart explicitly.
5. Account for long-lived tunnels: SIGTERM/SIGINT stop accepts and close active
   connections without waiting for natural completion. Clients must reconnect;
   established TCP sessions cannot migrate between processes or hosts.
6. Confirm new traffic, descriptor reclamation and no unexpected parser/timeout
   rejection before retiring the old service. Restore the saved binary/config and
   client destination if verification fails.

There is no config hot reload, connection handoff, dynamic discovery or automatic
DNS update. Repeated SIGTERM/SIGINT leave the immediate stop request unchanged.
Docker/systemd stop timeouts remain emergency watchdogs and do not delay an early
exit. In-place restart pauses new accepts until the replacement is ready.
