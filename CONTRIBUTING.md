# Contributing

Read [AGENTS.md](AGENTS.md) and the [architecture guide](docs/DESIGN.md) before
changing the parser or dataplane. Keep the project specialized: fixed SNI routing
and opaque TCP streams. New features need an explicit correctness or workload case.

Use Zig 0.16.0 and run the checks in
[the development workflow](.agent/workflows/development.md). Changes to observable
behavior must update README/config examples and relevant deterministic or Linux
integration tests. When execution is unavailable, report the missing checks and
use CI rather than implying a successful run.

Performance proposals need reproducible workloads, baseline/control runs and raw
results as described in [bench/README.md](bench/README.md). Avoid claims based only
on microbenchmarks or on another project's measured workload. Keep source changes
and documentation reviewable, preserve original-byte and ownership invariants,
and use accurate commit messages.
