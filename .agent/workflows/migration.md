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

## Compiler migration

Record a clean source baseline before changing the toolchain. Check the exact
release notes, language reference and installed/tagged standard library, including
deprecations, reflection, logical versus memory bit representation, Linux ABI,
build graph and startup DNS ownership. Keep the direct Linux serving path and its
bounded ownership/deadline/FIN contracts intact.

Update build guards, workflows, Docker checksums and all current documentation
together. Verify debug/safe/fast, parser mutations, real sockets/DNS, buffered and
splice controls, diagnostics, native images and the installer. After green checks,
repeat the API/deprecation audit before final performance comparisons.

Use the Benchmarks workflow to build each revision with its own exact compiler on
one runner. Zig 0.16.0 is retained only for the historical migration baseline;
set `options.baseline_zig` to `0.17.0` for a current baseline. Record both compilers
and build modes. Compare ordinary fast builds first; diagnostic/profiling records
are separate. Repeat and localize sustained throughput/CPU/tail regressions using
paired intervals, actor CPU/topology and generated assembly rather than treating
successful compilation as evidence of performance parity.
