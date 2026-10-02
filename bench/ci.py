#!/usr/bin/env python3
"""Run repeatable loopback workloads and a direct-origin control on Linux."""
import argparse
import json
import math
import os
from pathlib import Path
import platform
import resource
import socket
import statistics
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
CASES = [("bulk", count) for count in (1, 10, 100, 1000)] + [("latency", 100), ("churn", 16)]


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def wait_for_listener(process, port):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"process {process.pid} exited before listening; inspect its log")
        inodes = set()
        for fd in Path(f"/proc/{process.pid}/fd").iterdir():
            try:
                target = os.readlink(fd)
            except FileNotFoundError:
                continue
            if target.startswith("socket:["):
                inodes.add(target[8:-1])
        for line in Path(f"/proc/{process.pid}/net/tcp").read_text().splitlines()[1:]:
            fields = line.split()
            if fields[3] == "0A" and int(fields[1].split(":")[1], 16) == port and fields[9] in inodes:
                return
        time.sleep(.02)
    raise RuntimeError(f"process {process.pid} did not listen within 10s")


def stop(process):
    if process is None:
        return None
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
    return process.returncode


def decoded(value):
    return value.decode("utf-8", errors="replace") if isinstance(value, bytes) else (value or "")


def trial(args, mode, concurrency, topology, port, repeat):
    command = [sys.executable, str(HERE / "harness.py"), "run", "--port", str(port),
               "--mode", mode, "--concurrency", str(concurrency), "--duration", str(args.duration),
               "--inflight-bytes", str(args.inflight_bytes), "--drain-timeout", str(args.drain_timeout)]
    try:
        process = subprocess.run(command, capture_output=True, text=True,
                                 timeout=args.duration + args.drain_timeout + 60)
        stdout, stderr, returncode = process.stdout, process.stderr, process.returncode
        try:
            result = json.loads(stdout)
        except json.JSONDecodeError:
            result = {"valid": False, "errors": ["client did not emit a JSON result; inspect stdout/stderr"]}
    except subprocess.TimeoutExpired as exc:
        stdout, stderr, returncode = decoded(exc.stdout), decoded(exc.stderr), None
        result = {"valid": False, "errors": ["client exceeded setup + workload + drain wall-clock limit"]}
    passed = returncode == 0 and result.get("valid") is True and result.get("errors") == []
    record = {"topology": topology, "repeat": repeat, "mode": mode, "concurrency": concurrency,
              "passed": passed, "returncode": returncode, "result": result}
    stem = f"{mode}-{concurrency}-{topology}-{repeat}"
    (args.output / f"{stem}.json").write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    if not passed:
        (args.output / f"{stem}.stdout.txt").write_text(stdout, encoding="utf-8")
        (args.output / f"{stem}.stderr.txt").write_text(stderr, encoding="utf-8")
    print(f"{stem}: {'passed' if passed else 'FAILED'}", flush=True)
    return record


def summary(records, args):
    lines = ["## Loopback benchmark", "",
             "Generator, origin and proxy share this runner. Values describe this run; "
             "they do not establish a network throughput limit.", "",
             f"Payload window: {args.duration:g}s; repetitions: {args.repeats}; "
             f"bulk echo window: {args.inflight_bytes} bytes per stream.", "",
             "Medians are shown only when every requested repetition passed.", "",
             "| Mode | Streams | Topology | Passed | Echo Gbit/s | RTT p50 / p99 µs | Connections/s |",
             "| --- | ---: | --- | ---: | ---: | ---: | ---: |"]
    for mode, count in CASES:
        for topology in ("direct", "proxy"):
            selected = [r for r in records if r["mode"] == mode and r["concurrency"] == count and r["topology"] == topology]
            passed = sum(r["passed"] for r in selected)
            complete = len(selected) == args.repeats and passed == args.repeats
            def median(key):
                if not complete:
                    return "—"
                values = [r["result"].get(key) for r in selected]
                return f"{statistics.median(values):.3f}" if all(v is not None for v in values) else "—"
            lines.append(f"| {mode} | {count} | {topology} | {passed}/{args.repeats} | "
                         f"{median('echo_goodput_gbit_s') if mode == 'bulk' else '—'} | "
                         f"{median('latency_us_p50')} / {median('latency_us_p99')} | {median('connections_per_second')} |")
    lines += ["", "RTT includes generator/origin work. Direct and proxy trials alternate order between repetitions.",
              "Raw results, failures, configuration and environment metadata are in the artifact.", ""]
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with Path(os.environ["GITHUB_STEP_SUMMARY"]).open("a", encoding="utf-8") as output:
            output.write("\n".join(lines))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--duration", type=float, default=10)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--inflight-bytes", type=int, default=262144)
    parser.add_argument("--drain-timeout", type=float, default=15)
    args = parser.parse_args()
    if not math.isfinite(args.duration) or not 1 <= args.duration <= 60 or not 1 <= args.repeats <= 5:
        parser.error("duration must be 1..60 seconds and repeats must be 1..5")
    if not 65536 <= args.inflight_bytes <= 67108864 or not math.isfinite(args.drain_timeout) or not 0 < args.drain_timeout <= 120:
        parser.error("inflight-bytes must be 65536..67108864; drain-timeout must be finite and in (0, 120]")
    binary = str(Path(args.binary).resolve())
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    if hard != resource.RLIM_INFINITY and hard < 8192:
        parser.error("benchmark topology requires an fd hard limit of at least 8192")
    if soft != resource.RLIM_INFINITY and soft < 8192:
        resource.setrlimit(resource.RLIMIT_NOFILE, (8192, hard))
    args.output.mkdir(parents=True, exist_ok=True)
    metadata = {"commit": os.environ.get("GITHUB_SHA"), "run_id": os.environ.get("GITHUB_RUN_ID"),
                "build_mode": os.environ.get("BENCH_BUILD_MODE"), "kernel": platform.release(), "machine": platform.machine(),
                "python": platform.python_version(), "cpu_count": os.cpu_count(),
                "affinity": sorted(os.sched_getaffinity(0)), "duration_s": args.duration,
                "repeats": args.repeats, "inflight_bytes_per_stream": args.inflight_bytes,
                "drain_timeout_s": args.drain_timeout, "topology": "loopback, separate generator/origin/proxy processes",
                "environment": {}}
    for path in ("/proc/cpuinfo", "/proc/sys/net/ipv4/tcp_rmem", "/proc/sys/net/ipv4/tcp_wmem",
                 "/proc/sys/net/core/somaxconn", "/sys/fs/cgroup/cpu.max", "/sys/fs/cgroup/cpuset.cpus.effective",
                 "/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"):
        try:
            metadata["environment"][path] = Path(path).read_text()
        except OSError:
            metadata["environment"][path] = None
    records = []
    origin = proxy = None
    proxy_code = None
    try:
        with (args.output / "origin.log").open("wb") as origin_log, (args.output / "proxy.log").open("wb") as proxy_log:
            origin_port = free_port()
            origin = subprocess.Popen([sys.executable, str(HERE / "harness.py"), "serve", "--port", str(origin_port)],
                                      stdout=origin_log, stderr=origin_log)
            wait_for_listener(origin, origin_port)
            proxy_port = free_port()
            config = json.loads((HERE / "zigveil.json").read_text(encoding="utf-8"))
            config["listen"] = f"127.0.0.1:{proxy_port}"
            config["routes"][0]["backend"] = f"127.0.0.1:{origin_port}"
            config_path = args.output.resolve() / "config.json"
            config_path.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")
            proxy = subprocess.Popen([binary, str(config_path)], stdout=proxy_log, stderr=proxy_log)
            wait_for_listener(proxy, proxy_port)
            for repeat in range(1, args.repeats + 1):
                for mode, count in CASES:
                    topologies = ("direct", "proxy") if repeat % 2 else ("proxy", "direct")
                    for topology in topologies:
                        if origin.poll() is not None or proxy.poll() is not None:
                            raise RuntimeError("benchmark origin/proxy exited unexpectedly; inspect logs")
                        port = origin_port if topology == "direct" else proxy_port
                        records.append(trial(args, mode, count, topology, port, repeat))
    finally:
        proxy_code = stop(proxy)
        origin_code = stop(origin)
        metadata["proxy_exit_code"] = proxy_code
        metadata["origin_exit_code"] = origin_code
        (args.output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
        summary(records, args)
    return int(proxy_code != 0 or any(not record["passed"] for record in records))


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError) as exc:
        print(f"benchmark: {exc}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        sys.exit(130)
