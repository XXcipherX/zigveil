#!/usr/bin/env python3
"""Paired Linux relay laboratory; barriers, process ownership and raw evidence."""
import argparse
import json
import math
import os
from pathlib import Path
import platform
import random
import resource
import select
import signal
import socket
import statistics
import subprocess
import sys
import time

import collect
import profiling

HERE = Path(__file__).resolve().parent
DEFAULT_CASES = "bulk:1,bulk:10,bulk:100,bulk:1000,latency:1,latency:10,latency:100,loaded-latency:100,churn:16"
GAUGES = {"recv_max", "send_max", "splice_read_max", "splice_write_max", "pipe_max_capacity", "shared_pipe_capacity", "pipe_live", "epoll_max_batch", "active", "last_other_io_errno"}


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def wait_for_listener(process, port):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"PID {process.pid} exited before listening")
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
    raise RuntimeError(f"PID {process.pid} did not listen")


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


def read_optional(path):
    try:
        return Path(path).read_text().strip()
    except OSError:
        return None


def socket_pressure():
    result = {"sockstat": read_optional("/proc/net/sockstat")}
    text = (read_optional("/proc/net/netstat") or "").splitlines()
    keys = {"TCPMemoryPressures", "TCPMemoryPressuresChrono", "TCPRcvQDrop", "TCPBacklogDrop",
            "TCPFromZeroWindowAdv", "TCPToZeroWindowAdv", "TCPWantZeroWindowAdv", "TCPWinProbe", "TCPRcvCollapsed"}
    for names, values in zip(text[::2], text[1::2]):
        result.update({key: int(value) for key, value in zip(names.split()[1:], values.split()[1:]) if key in keys})
    return result


def delta(before, after):
    return {k: after[k] if k in GAUGES else (after[k] - before.get(k, 0)) % (1 << 64)
            for k in after if k != "event"}


def proxy_snapshot(process, path, metrics):
    offset = path.stat().st_size
    os.kill(process.pid, signal.SIGUSR1)
    deadline = time.monotonic() + 5
    result = {}
    while time.monotonic() < deadline:
        with path.open() as log:
            log.seek(offset)
            for line in log:
                try:
                    value = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if value.get("event") in ("stats", "dataplane"):
                    result[value["event"]] = value
        if "stats" in result and (not metrics or "dataplane" in result):
            return dict(result, sampled_ns=time.monotonic_ns())
        if process.poll() is not None:
            raise RuntimeError("proxy exited while collecting diagnostics")
        time.sleep(.001)
    raise RuntimeError("proxy did not acknowledge SIGUSR1")


def send_command(control, command):
    control.sendall(json.dumps(dict(command=command)).encode() + b"\n")


def wait_event(control, reader, event, seconds, actors=None, peaks=None):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        ready, _, _ = select.select([control], [], [], min(.1, max(0, deadline - time.monotonic())))
        if actors:
            for name, process in actors.items():
                sample = collect.snapshot(process.pid)
                peaks[name] = max(peaks.get(name, 0), sample["rss_bytes"])
        if ready:
            line = reader.readline()
            if not line:
                raise RuntimeError(f"generator exited before {event}")
            value = json.loads(line)
            if value.get("event") != event:
                raise RuntimeError(f"expected {event}, received {value}")
            return value
    raise RuntimeError(f"coordinator timed out waiting for {event}")


def spawn(command, cpu, **kwargs):
    # A single-threaded coordinator changes only the new Linux child's affinity.
    return subprocess.Popen(command, preexec_fn=lambda: os.sched_setaffinity(0, {cpu}), **kwargs)


class Workload:
    def __init__(self, directory, name, command, cpu):
        self.name, self.process = name, None
        self.control, peer = socket.socketpair()
        self.reader = self.control.makefile("rb", buffering=0)
        self.stdout_path = directory / f"{name}.stdout.txt"
        self.stdout = self.stdout_path.open("wb")
        self.stderr = (directory / f"{name}.stderr.txt").open("wb")
        try:
            self.process = spawn(command + ["--control-fd", str(peer.fileno())], cpu,
                                 pass_fds=(peer.fileno(),), stdout=self.stdout, stderr=self.stderr)
        except OSError:
            self.close()
            raise
        finally:
            peer.close()

    def send(self, command):
        send_command(self.control, command)

    def event(self, name, seconds, actors=None, peaks=None):
        return wait_event(self.control, self.reader, name, seconds, actors, peaks)

    def result(self):
        self.process.wait(timeout=10)
        self.stdout.flush()
        return json.loads(self.stdout_path.read_text())

    def close(self):
        stop(self.process)
        self.reader.close()
        self.control.close()
        self.stdout.close()
        self.stderr.close()


def combine_bulk(results, windows):
    if len(results) == 1:
        return dict(results[0])
    result = dict(results[0], concurrency=sum(r["concurrency"] for r in results), generator_workers=len(results))
    for key in ("bytes_client_to_backend", "bytes_backend_to_client", "connections", "completed_streams", "failed_streams",
                "unfinished_streams", "unfinished_workers", "corruption_events", "error_count", "unreturned_bytes"):
        result[key] = sum(r.get(key, 0) for r in results)
    result["valid"] = all(r["valid"] for r in results)
    result["errors"] = list(dict.fromkeys(e for r in results for e in r["errors"]))[:16]
    start = min(w["start_ns"] for w in windows)
    end = max(w["start_ns"] + round(r["seconds"] * 1e9) for w, r in zip(windows, results))
    result["seconds"] = (end - start) / 1e9
    result["drain_seconds"] = max(0, result["seconds"] - result["duration_requested_s"])
    result["max_observed_inflight_bytes_per_stream"] = max(r["max_observed_inflight_bytes_per_stream"] for r in results)
    result["timed_out"] = any(r.get("timed_out", False) for r in results)
    result["echo_goodput_gbit_s"] = result["bytes_backend_to_client"] * 8 / result["seconds"] / 1e9 if result["valid"] else None
    result["aggregate_forwarded_gbit_s"] = (result["bytes_client_to_backend"] + result["bytes_backend_to_client"]) * 8 / result["seconds"] / 1e9 if result["valid"] else None
    return result


def metric(record, key):
    if not record.get("passed") or record.get("diagnostic_record"):
        return None
    result = record["result"]
    proxy = [v for k, v in record.get("cpu", {}).items() if k.startswith("proxy")]
    forwarded = record.get("forwarded_bytes_window", 0)
    if key == "cpu_gbit":
        return sum(p["cpu_seconds"] for p in proxy) / (forwarded * 8 / 1e9) if proxy and forwarded else None
    if key == "rss":
        return sum(p["rss_bytes"] for p in proxy) if proxy else None
    if key in ("cycles_byte", "instructions_byte"):
        return record.get("perf", {}).get("cycles_per_forwarded_byte" if key == "cycles_byte" else "instructions_per_forwarded_byte")
    if key == "syscalls_gib":
        values = record.get("perf", {}).get("values", {})
        if "syscalls:sys_enter_recvfrom" in values and "syscalls:sys_enter_sendto" in values:
            calls = sum(v for k, v in values.items() if k.startswith("syscalls:sys_enter_"))
            return calls / (forwarded / (1 << 30)) if forwarded else None
        return record.get("derived", {}).get(key)
    return result.get(key)


def spread(values):
    if not values or any(x is None for x in values):
        return None
    median, mean = statistics.median(values), statistics.mean(values)
    return dict(median=median, min=min(values), max=max(values), mad=statistics.median(abs(x - median) for x in values),
                cv=statistics.pstdev(values) / abs(mean) if mean else None)


def paired(before, after):
    if len(before) != len(after) or not before or any(v is None or v <= 0 for v in before + after):
        return None
    ratios = [b / a for a, b in zip(before, after)]
    bounds = None
    if len(ratios) >= 3:
        rng = random.Random(0x706169726564)
        estimates = sorted(statistics.median(rng.choices(ratios, k=len(ratios))) for _ in range(4000))
        bounds = [100 * (estimates[100] - 1), 100 * (estimates[3899] - 1)]
    return dict(delta_percent=(statistics.median(ratios) - 1) * 100,
                absolute_delta=statistics.median(after) - statistics.median(before), bootstrap_95_percent=bounds,
                pairs=len(ratios), ratios=ratios)


def derived_metrics(metrics, forwarded):
    if not metrics or not forwarded:
        return {}
    gib = forwarded / (1 << 30)
    def ratio(a, b):
        return metrics[a] / metrics[b] if metrics.get(b) else None
    fields = ("recv_attempts", "send_attempts", "splice_read_attempts", "splice_write_attempts", "pipe_read", "pipe2", "fcntl", "epoll_wait", "epoll_add", "epoll_mod", "epoll_del",
              "accept4", "connect", "getsockopt", "shutdown", "close")
    read_calls = metrics.get("recv_attempts", 0) + metrics.get("splice_read_attempts", 0)
    write_calls = metrics.get("send_attempts", 0) + metrics.get("splice_write_attempts", 0)
    return dict(syscalls_gib=sum(metrics.get(k, 0) for k in fields) / gib,
                syscall_scope="counted relay calls, excluding socket/setsockopt, signal reads and vDSO",
                recv_calls_gib=metrics["recv_attempts"] / gib, send_calls_gib=metrics["send_attempts"] / gib,
                epoll_events_gib=metrics["epoll_events"] / gib, recv_again_fraction=ratio("recv_again", "recv_attempts"),
                send_again_fraction=ratio("send_again", "send_attempts"), recv_mean_bytes=ratio("recv_bytes", "recv_success"),
                send_mean_bytes=ratio("send_bytes", "send_success"), events_per_wait=ratio("epoll_events", "epoll_wait"),
                splice_read_calls_gib=metrics.get("splice_read_attempts", 0) / gib, splice_write_calls_gib=metrics.get("splice_write_attempts", 0) / gib,
                input_again_fraction=(metrics.get("recv_again", 0) + metrics.get("splice_read_again", 0)) / read_calls if read_calls else None,
                output_again_fraction=(metrics.get("send_again", 0) + metrics.get("splice_write_again", 0)) / write_calls if write_calls else None,
                drive_per_event=ratio("drive_calls", "connection_events"), no_progress_fraction=ratio("drive_no_progress", "drive_calls"))


def trial(args, mode, count, variant, ring, repeat, capability, diagnostic=False):
    stem = f"{mode}-{count}-{variant}-{ring}-p{args.processes}-{repeat}" + ("-record" if diagnostic else "")
    directory = args.output / stem
    directory.mkdir()
    cpus = args.available_cpus
    proxy_count = 0 if variant == "direct" else args.baseline_processes if variant == "baseline" else args.processes
    mapping = {f"proxy{i}": cpus[i % len(cpus)] for i in range(proxy_count)}
    # Direct control keeps generator/origin on the same CPUs as proxy trials.
    mapping["origin"] = cpus[args.topology_processes % len(cpus)]
    isolated_probe = mode == "loaded-latency"
    worker_count = min(args.generator_workers, count) if mode in ("bulk", "loaded-latency") else 1
    names = ["generator"] if worker_count == 1 else [f"generator{i}" for i in range(worker_count)]
    for i, name in enumerate(names):
        mapping[name] = cpus[(args.topology_processes + 1 + i) % len(cpus)]
    if isolated_probe:
        unused = [cpu for cpu in cpus if cpu not in mapping.values() and cpu not in cpus[:args.topology_processes]]
        mapping["probe"] = unused[0] if unused else mapping["origin"]
    origin = probe = None
    proxies, files, actors = [], [], {}
    clients, generators = [], []
    perf = None
    record = dict(mode=mode, concurrency=count, variant=variant, ring=ring, repeat=repeat,
                  process_count=proxy_count, affinity=mapping, diagnostic_record=diagnostic, passed=False)
    record["socket_pressure_before"] = socket_pressure()
    record["probe_has_distinct_cpu"] = isolated_probe and mapping["probe"] not in [cpu for name, cpu in mapping.items() if name != "probe"]
    core_groups = {}
    for name, cpu in mapping.items():
        topology = args.cpu_topology[str(cpu)]
        if topology["physical_package_id"] is None or topology["core_id"] is None:
            core_groups = None
            break
        core = topology["physical_package_id"] + ":" + topology["core_id"]
        core_groups.setdefault(core, []).append(name)
    record["actors_sharing_visible_cores"] = ([names for names in core_groups.values() if len(names) > 1]
                                              if core_groups is not None else None)
    effective_ring = args.baseline_ring if variant == "baseline" and args.baseline_ring else ring
    record["configured_ring"] = effective_ring
    metrics_enabled = variant == "metrics"
    try:
        origin_port = free_port()
        origin_log = (directory / "origin.log").open("wb")
        files.append(origin_log)
        origin_command = [args.native_binary] if args.origin_engine == "native" else [sys.executable, str(HERE / "harness.py")]
        origin_options = ["--echo-io", args.origin_io] if args.origin_engine == "native" else []
        origin = spawn(origin_command + ["serve", "--port", str(origin_port)] + origin_options, mapping["origin"],
                       stdout=origin_log, stderr=origin_log)
        actors["origin"] = origin
        wait_for_listener(origin, origin_port)
        if args.origin_engine == "native":
            deadline = time.monotonic() + 5
            while True:
                try:
                    record["origin_ready"] = json.loads((directory / "origin.log").read_text().splitlines()[0])
                    break
                except (json.JSONDecodeError, IndexError):
                    if time.monotonic() > deadline:
                        raise RuntimeError("native origin did not report its actual I/O mode")
                    time.sleep(.001)
        port = origin_port
        if proxy_count:
            port = free_port()
            config = dict(listen=f"127.0.0.1:{port}", routes=[dict(sni="example.com", backend=f"127.0.0.1:{origin_port}")],
                          max_connections=max(2048, count + 32), max_handshakes=64, relay_buffer_bytes=effective_ring,
                          idle_timeout_ms=0, stats_interval_ms=0, log_level="none", log_format="json", reuse_port=proxy_count > 1)
            config_path = directory / "config.json"
            config_path.write_text(json.dumps(config, indent=2) + "\n")
            for i in range(proxy_count):
                path = directory / f"proxy{i}.log"
                log = path.open("wb")
                files.append(log)
                process = spawn([args.binaries[variant], str(config_path.resolve())], mapping[f"proxy{i}"], stdout=log, stderr=log)
                proxies.append((process, path))
                actors[f"proxy{i}"] = process
                wait_for_listener(process, port)
        generator_mode = "bulk" if isolated_probe else mode
        generator_engine = "native" if args.generator_engine == "native" and generator_mode == "bulk" else "python"
        record["generator_engine"], record["origin_engine"] = generator_engine, args.origin_engine
        generator_command = [args.native_binary] if generator_engine == "native" else [sys.executable, str(HERE / "harness.py")]
        for i, name in enumerate(names):
            streams = count // worker_count + (i < count % worker_count)
            command = generator_command + ["run", "--port", str(port), "--mode", generator_mode,
                       "--concurrency", str(streams), "--duration", str(args.duration), "--warmup", str(args.warmup),
                       "--chunk-bytes", str(args.chunk_bytes), "--inflight-bytes", str(args.inflight_bytes),
                       "--drain-timeout", str(args.drain_timeout)]
            if generator_engine == "python" and args.warmup_bytes is not None:
                command += ["--warmup-bytes", str(args.warmup_bytes)]
            client = Workload(directory, name, command, mapping[name])
            clients.append(client)
            generators.append(client)
            actors[name] = client.process
        if isolated_probe:
            probe_command = [sys.executable, str(HERE / "harness.py"), "run", "--port", str(port), "--mode", "latency",
                             "--concurrency", "1", "--duration", str(args.duration), "--warmup", str(args.warmup),
                             "--drain-timeout", str(args.drain_timeout)]
            if args.warmup_bytes is not None:
                probe_command += ["--warmup-bytes", str(args.warmup_bytes)]
            probe = Workload(directory, "probe", probe_command, mapping["probe"])
            clients.append(probe)
            actors["probe"] = probe.process
        record["ready"] = {client.name: client.event("ready", 90) for client in clients}
        before_stats = [proxy_snapshot(p, path, metrics_enabled) for p, path in proxies]
        perf_enabled = False
        if proxies:
            perf = profiling.Perf(capability, [p.pid for p, _ in proxies], directory / "proxy", record=diagnostic)
            perf_enabled = perf.gate("enable")
        before = {name: collect.snapshot(p.pid) for name, p in actors.items()}
        peaks = {name: s["rss_bytes"] for name, s in before.items()}
        go_ns = time.monotonic_ns()
        for client in clients:
            client.send("go")
        windows = [client.event("window", args.duration + 30, actors, peaks) for client in generators]
        window = dict(start_ns=min(w["start_ns"] for w in windows), end_ns=max(w["end_ns"] for w in windows),
                      tx=sum(w["tx"] for w in windows), rx=sum(w["rx"] for w in windows))
        if isolated_probe:
            record["probe_window"] = probe.event("window", 30)
        notified_ns = time.monotonic_ns()
        after = {name: collect.snapshot(p.pid) for name, p in actors.items()}
        after_stats = [proxy_snapshot(p, path, metrics_enabled) for p, path in proxies]
        stats = [delta(a["stats"], b["stats"]) for a, b in zip(before_stats, after_stats)]
        forwarded = sum(s["bytes_client_to_backend"] + s["bytes_backend_to_client"] for s in stats) if stats else window["tx"] + window["rx"]
        if not stats and isolated_probe:
            forwarded += record["probe_window"]["tx"] + record["probe_window"]["rx"]
        record["forwarded_bytes_window"] = forwarded
        record["stats_window"] = stats
        record["cpu"] = {name: collect.difference(before[name], after[name], forwarded, peaks[name]) for name in actors}
        record["measurement"] = dict(generator=window, coordinator_go_ns=go_ns, notification_ns=notified_ns,
                                     generator_windows=windows,
                                     start_skew_ns=window["start_ns"] - go_ns, end_notification_skew_ns=notified_ns - window["end_ns"],
                                     proc_before=before, proc_after=after, stats_before_ns=[s["sampled_ns"] for s in before_stats],
                                     stats_after_ns=[s["sampled_ns"] for s in after_stats])
        if metrics_enabled:
            values = [delta(a["dataplane"], b["dataplane"]) for a, b in zip(before_stats, after_stats)]
            metrics = {k: (max(v[k] for v in values) if k in GAUGES - {"pipe_live", "active"} else sum(v[k] for v in values)) for k in values[0]}
            record["dataplane"] = metrics
            record["derived"] = derived_metrics(metrics, forwarded)
            record["maxima_scope"] = "process lifetime including warmup; counters are window deltas"
        if perf:
            record["perf"] = perf.finish(forwarded)
            perf = None
            if not perf_enabled:
                record["perf"]["available"] = False
        for client in clients:
            client.send("ack")
        for client in clients:
            client.event("drained", args.drain_timeout + 20)
        post = []
        for p, path in proxies:
            deadline = time.monotonic() + 5
            while True:
                snapshot = proxy_snapshot(p, path, metrics_enabled)
                if snapshot["stats"]["active"] == 0:
                    break
                if time.monotonic() >= deadline:
                    raise RuntimeError("proxy did not reclaim connections after drain")
                time.sleep(.02)
            # A baseline may predate splice or use its own default. The retained
            # architecture has either no pipes or exactly four process-owned fds.
            splice = args.baseline_splice is not False if variant == "baseline" else args.relay_splice
            post.append(dict(proc=collect.snapshot(p.pid), stats=snapshot["stats"], allowed_idle_fds=[6, 10] if splice else [6]))
        record["after_drain"] = post
        for client in clients:
            client.send("finish")
        results = [client.result() for client in generators]
        record["generator_results"] = results
        result = combine_bulk(results, windows)
        if isolated_probe:
            probe_result = probe.result()
            record["probe_result"] = probe_result
            result["mode"] = "loaded-latency"
            for key in ("bytes_client_to_backend", "bytes_backend_to_client", "connections", "completed_streams", "failed_streams",
                        "unfinished_streams", "corruption_events", "error_count"):
                result[key] += probe_result.get(key, 0)
            for key in probe_result:
                if key.startswith("latency_") or key in ("round_trips", "round_trips_per_second"):
                    result[key] = probe_result[key]
            result["valid"] = result["valid"] and probe_result["valid"] and probe.process.returncode == 0
            result["errors"] += probe_result["errors"]
            if result["valid"]:
                result["echo_goodput_gbit_s"] = result["bytes_backend_to_client"] * 8 / result["seconds"] / 1e9
                result["aggregate_forwarded_gbit_s"] = (result["bytes_client_to_backend"] + result["bytes_backend_to_client"]) * 8 / result["seconds"] / 1e9
            else:
                result["echo_goodput_gbit_s"] = result["aggregate_forwarded_gbit_s"] = None
        record["result"] = result
        record["generator_exit_codes"] = [client.process.returncode for client in generators]
        record["passed"] = all(code == 0 for code in record["generator_exit_codes"]) and result.get("valid") is True and result.get("errors") == []
        if any(s["stats"]["io_errors"] or s["stats"]["rejected"] or s["stats"]["timeouts"] for s in post):
            record["passed"] = False
            record["proxy_failure"] = "nonzero I/O/rejection/timeout counters"
        if any(s["proc"]["fds"] not in s["allowed_idle_fds"] or s["stats"]["accepted"] != s["stats"]["closed"] for s in post):
            record["passed"] = False
            record["proxy_failure"] = "fd or connection ownership did not return to idle"
    except (OSError, RuntimeError, ValueError, subprocess.TimeoutExpired) as exc:
        record["error"] = repr(exc)
    finally:
        if not record["passed"]:
            record["socket_pressure_failure"] = socket_pressure()
            record["failure_children"] = {name: dict(pid=p.pid, returncode=p.poll()) for name, p in actors.items()}
            record["failure_generator_logs"] = {}
            for client in clients:
                client.stdout.flush()
                record["failure_generator_logs"][client.name] = dict(
                    stdout=(read_optional(client.stdout_path) or "")[-4096:],
                    stderr=(read_optional(client.stderr.name) or "")[-4096:])
        if perf:
            record["perf"] = perf.finish(0)
        for client in clients:
            client.close()
        record["proxy_exit_codes"] = [stop(p) for p, _ in proxies]
        stop(origin)
        if any(code != 0 for code in record["proxy_exit_codes"]):
            record["passed"] = False
        for file in files:
            file.close()
        (directory / "record.json").write_text(json.dumps(record, indent=2) + "\n")
    visible = {k: v for k, v in record.items() if k != "measurement"}
    print(json.dumps(dict(event="trial", **visible), sort_keys=True), flush=True)
    return record


def summarize(records, args):
    groups = []
    for mode, count in args.cases:
        for ring in args.rings:
            for variant in args.variants:
                selected = sorted((r for r in records if not r["diagnostic_record"] and r["mode"] == mode and r["concurrency"] == count
                                   and r["ring"] == (0 if variant == "direct" else ring) and r["variant"] == variant), key=lambda r: r["repeat"])
                if variant == "direct" and ring != args.rings[0]:
                    continue
                keys = ("echo_goodput_gbit_s", "cpu_gbit", "cycles_byte", "instructions_byte", "syscalls_gib", "latency_us_p50",
                        "latency_us_p99", "latency_us_p999", "rss", "connections_per_second", "round_trips_per_second")
                complete = len(selected) == args.repeats and all(r["passed"] for r in selected)
                values = {k: spread([metric(r, k) for r in selected]) if complete else None for k in keys}
                comparisons = {}
                base = sorted((r for r in records if not r["diagnostic_record"] and r["mode"] == mode and r["concurrency"] == count
                               and r["ring"] == ring and r["variant"] == "baseline"), key=lambda r: r["repeat"])
                if variant in ("candidate", "metrics") and complete and len(base) == args.repeats and all(r["passed"] for r in base):
                    comparisons = {k: paired([metric(r, k) for r in base], [metric(r, k) for r in selected]) for k in keys}
                ordinary = sorted((r for r in records if not r["diagnostic_record"] and r["mode"] == mode and r["concurrency"] == count
                                   and r["ring"] == ring and r["variant"] == "candidate"), key=lambda r: r["repeat"])
                observer = {}
                if variant == "metrics" and complete and len(ordinary) == args.repeats and all(r["passed"] for r in ordinary):
                    observer = {k: paired([metric(r, k) for r in ordinary], [metric(r, k) for r in selected]) for k in keys}
                process_count = selected[0].get("process_count", 1) if selected else None
                base_processes = base[0].get("process_count", 1) if base else None
                scaling = None
                throughput = comparisons.get("echo_goodput_gbit_s")
                if throughput and process_count and base_processes and process_count != base_processes:
                    factor = process_count / base_processes
                    bounds = throughput["bootstrap_95_percent"]
                    scaling = dict(processes_ratio=factor, efficiency_percent=(throughput["delta_percent"] + 100) / factor,
                                   bootstrap_95_percent=[(x + 100) / factor for x in bounds] if bounds else None)
                groups.append(dict(mode=mode, concurrency=count, ring=0 if variant == "direct" else ring, variant=variant,
                                   process_count=process_count, scaling_efficiency=scaling,
                                   configured_ring=selected[0].get("configured_ring", ring) if selected else None,
                                   passed=sum(r["passed"] for r in selected), requested=args.repeats, metrics=values,
                                   vs_baseline=comparisons, vs_candidate=observer))
    (args.output / "summary.json").write_text(json.dumps(groups, indent=2) + "\n")
    print(json.dumps(dict(event="summary", groups=groups), sort_keys=True), flush=True)
    lines = ["## Paired relay measurements", "", "One runner; production fast and diagnostic counters are shown separately.", "",
             "| Workload | Configured ring | Variant / proxies | Passed | Echo Gbit/s (CV) | CPU s/Gbit | p50 / p99 / p99.9 µs | RSS MiB | Decision for this sample |",
             "| --- | ---: | --- | ---: | ---: | ---: | ---: | ---: | --- |"]
    def show(value):
        return f"{value['median']:.4g}" if value else "—"
    for group in groups:
        value = group["metrics"]
        throughput = value["echo_goodput_gbit_s"]
        cv = f" ({throughput['cv']:.1%})" if throughput and throughput["cv"] is not None else ""
        rss = f"{value['rss']['median'] / (1 << 20):.2f}" if value["rss"] else "—"
        lines.append(f"| {group['mode']}:{group['concurrency']} | {group['configured_ring']} | {group['variant']} / {group['process_count']} | {group['passed']}/{group['requested']} | "
                     f"{show(throughput)}{cv} | {show(value['cpu_gbit'])} | {show(value['latency_us_p50'])} / "
                     f"{show(value['latency_us_p99'])} / {show(value['latency_us_p999'])} | {rss} | {decision(group)} |")
    labels = (("echo_goodput_gbit_s", "Echo"), ("cpu_gbit", "CPU/Gbit"), ("cycles_byte", "Cycles/byte"),
              ("instructions_byte", "Instructions/byte"), ("syscalls_gib", "Syscalls/GiB"), ("latency_us_p50", "p50"),
              ("latency_us_p99", "p99"), ("latency_us_p999", "p99.9"), ("rss", "RSS"), ("connections_per_second", "Churn/s"))
    for comparison, title in (("vs_baseline", "Paired change against baseline"), ("vs_candidate", "Observer effect: counters against ordinary candidate")):
        lines += ["", f"### {title}", "", "Percent change and 95% bootstrap interval; lower CPU, latency and RSS are better.", "",
                  "| Workload / ring | Variant | " + " | ".join(label for _, label in labels) + " |",
                  "| --- | --- | " + " | ".join("---:" for _ in labels) + " |"]
        for group in groups:
            changes = group[comparison]
            if changes:
                lines.append(f"| {group['mode']}:{group['concurrency']} / {group['ring']} | {group['variant']} | " +
                             " | ".join(show_change(changes.get(key)) for key, _ in labels) + " |")
    lines += ["", "Raw records include MAD/CV/min/max, every actor's CPU, memory/fd reclamation, window skew and optional profiling.",
              "p99.9 needs 10,000 retained samples; confidence intervals describe these pairs, not future hosts.", ""]
    lines += ["Perf tracepoint counts include the available syscalls listed in metadata. With basic profiling only the metrics variant has counted relay calls; its scope excludes socket/setsockopt, signal reads and clock calls.", ""]
    for group in groups:
        if group["variant"] == "candidate" and group["scaling_efficiency"]:
            scaling = group["scaling_efficiency"]
            lines.append(f"{group['mode']}:{group['concurrency']} scaling efficiency: {scaling['efficiency_percent']:.2f}% "
                         f"for {scaling['processes_ratio']:g}× proxy processes. Inspect generator/origin saturation before treating this as a scaling ceiling.\n")
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with Path(os.environ["GITHUB_STEP_SUMMARY"]).open("a") as output:
            output.write("\n".join(lines))


def show_change(value):
    if value is None:
        return "—"
    bounds = value["bootstrap_95_percent"]
    return f"{value['delta_percent']:+.2f}%" + (f" [{bounds[0]:+.2f}, {bounds[1]:+.2f}]" if bounds else "")


def decision(group):
    if group["passed"] != group["requested"]:
        return "incomplete / failed"
    if group["variant"] != "candidate":
        return "diagnostic" if group["variant"] == "metrics" else "control"
    key = "connections_per_second" if group["mode"] == "churn" else "latency_us_p99" if group["mode"] == "latency" else "echo_goodput_gbit_s"
    comparison = group["vs_baseline"].get(key)
    bounds = comparison["bootstrap_95_percent"] if comparison else None
    if not bounds:
        return "insufficient pairs"
    lower_is_better = key == "latency_us_p99"
    if bounds[0] > 0:
        return f"{'regression' if lower_is_better else 'gain'} in {key}"
    if bounds[1] < 0:
        return f"{'gain' if lower_is_better else 'regression'} in {key}"
    return "no resolved change"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True)
    parser.add_argument("--baseline")
    parser.add_argument("--metrics-binary")
    parser.add_argument("--native-binary", help="optional separately built native workload tool")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--duration", type=float, default=10)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--workloads", default=DEFAULT_CASES)
    parser.add_argument("--rings", default="65536")
    parser.add_argument("--processes", type=int, default=1)
    parser.add_argument("--profiling", choices=("basic", "perf-stat", "perf-record"), default="perf-stat")
    parser.add_argument("--options", default="{}", help="JSON: chunk_bytes, inflight_bytes, warmup, variants, drain_timeout, baseline_ring")
    args = parser.parse_args()
    options = json.loads(args.options)
    if set(options) - {"chunk_bytes", "inflight_bytes", "warmup", "warmup_bytes", "variants", "drain_timeout", "generator", "generator_workers", "origin", "origin_io", "baseline_ring", "baseline_processes", "baseline_zig", "cpu", "relay_splice", "baseline_splice"}:
        parser.error("unknown laboratory option")
    if options.get("baseline_zig", "0.16.0") not in ("0.16.0", "0.17.0"):
        parser.error("baseline_zig must be an exact supported release: 0.16.0 or 0.17.0")
    args.chunk_bytes, args.inflight_bytes = int(options.get("chunk_bytes", 65536)), int(options.get("inflight_bytes", 262144))
    args.warmup, args.drain_timeout = float(options.get("warmup", 1)), float(options.get("drain_timeout", 15))
    args.warmup_bytes = options.get("warmup_bytes")
    if args.warmup_bytes is not None and (type(args.warmup_bytes) is not int or not 1 <= args.warmup_bytes <= 1048576):
        parser.error("warmup_bytes must be 1..1048576")
    args.baseline_ring = options.get("baseline_ring")
    args.build_cpu = options.get("cpu", os.environ.get("BENCH_CPU"))
    args.generator_workers = options.get("generator_workers", 1)
    args.origin_io = options.get("origin_io", "buffered")
    if type(args.generator_workers) is not int or args.generator_workers not in (1, 2):
        parser.error("generator_workers must be 1 or 2")
    if args.origin_io not in ("buffered", "splice"):
        parser.error("origin_io must be buffered or splice")
    args.relay_splice = options.get("relay_splice", {"true": True, "false": False}.get(os.environ.get("BENCH_SPLICE"), True))
    args.baseline_splice = options.get("baseline_splice")
    args.relay_quantum = 262144
    if args.baseline_splice is not None and type(args.baseline_splice) is not bool:
        parser.error("baseline_splice must be boolean")
    args.baseline_processes = options.get("baseline_processes", args.processes)
    if type(args.baseline_processes) is not int or args.baseline_processes not in (1, 2, 4):
        parser.error("baseline_processes must be 1, 2 or 4")
    args.topology_processes = max(args.processes, args.baseline_processes)
    if args.build_cpu not in (None, "baseline", "native", "x86_64_v3") or (args.relay_splice is not None and type(args.relay_splice) is not bool):
        parser.error("cpu must be baseline/native/x86_64_v3 and relay_splice must be boolean")
    if args.baseline_ring is not None and args.baseline_ring not in (4096, 8192, 16384, 32768, 65536):
        parser.error("baseline_ring must be a supported power of two or null")
    if args.native_binary:
        args.native_binary = str(Path(args.native_binary).resolve())
    args.generator_engine = options.get("generator", "native" if args.native_binary else "python")
    args.origin_engine = options.get("origin", "native" if args.native_binary else "python")
    if any(engine not in ("python", "native") for engine in (args.generator_engine, args.origin_engine)) or (
            not args.native_binary and "native" in (args.generator_engine, args.origin_engine)):
        parser.error("native generator/origin requires --native-binary; engine must be python or native")
    if args.origin_engine != "native" and args.origin_io != "buffered":
        parser.error("splice origin I/O requires the native origin")
    args.binaries = {"candidate": str(Path(args.binary).resolve())}
    if args.baseline:
        args.binaries["baseline"] = str(Path(args.baseline).resolve())
    if args.metrics_binary:
        args.binaries["metrics"] = str(Path(args.metrics_binary).resolve())
    args.variants = options.get("variants", ["direct"] + list(args.binaries))
    if not args.variants or len(set(args.variants)) != len(args.variants) or any(v != "direct" and v not in args.binaries for v in args.variants):
        parser.error("variants must select distinct provided binaries or direct")
    args.cases = [(m, int(n)) for m, n in (case.split(":") for case in args.workloads.split(","))]
    if any(m not in ("bulk", "latency", "churn", "loaded-latency") or not 1 <= n <= 10000 for m, n in args.cases) or len(set(args.cases)) != len(args.cases):
        parser.error("workloads must be distinct MODE:STREAMS, streams 1..10000")
    args.rings = [int(x) for x in args.rings.split(",")]
    if len(set(args.rings)) != len(args.rings) or any(n not in (4096, 8192, 16384, 32768, 65536) for n in args.rings):
        parser.error("rings must be distinct supported powers of two")
    if not math.isfinite(args.duration) or not 1 <= args.duration <= 60 or not 1 <= args.repeats <= 9:
        parser.error("duration 1..60, repeats 1..9")
    if args.processes not in (1, 2, 4):
        parser.error("processes must be 1, 2 or 4")
    if not 256 <= args.chunk_bytes <= 1048576 or args.chunk_bytes % 256 or not args.chunk_bytes <= args.inflight_bytes <= 67108864:
        parser.error("invalid chunk/window combination")
    if not math.isfinite(args.warmup) or not 0 <= args.warmup <= 30 or not math.isfinite(args.drain_timeout) or not 0 < args.drain_timeout <= 120:
        parser.error("invalid warmup/drain timeout")
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    max_streams = max(n for _, n in args.cases)
    required = max(8192, max_streams * 2 + 256, max(2048, max_streams + 32) * 2 + 12)
    if hard != resource.RLIM_INFINITY and hard < required:
        parser.error(f"fd hard limit must be at least {required}")
    if soft != resource.RLIM_INFINITY and soft < required:
        resource.setrlimit(resource.RLIMIT_NOFILE, (required, hard))
    args.output.mkdir(parents=True, exist_ok=True)
    cpus = sorted(os.sched_getaffinity(0))
    args.available_cpus = cpus
    args.cpu_topology = collect.cpu_topology(cpus)
    metadata = dict(commit=os.environ.get("GITHUB_SHA"), baseline_sha=os.environ.get("BENCH_BASELINE_SHA"),
                    candidate_sha=os.environ.get("GITHUB_SHA"), build_mode=os.environ.get("BENCH_BUILD_MODE"),
                    baseline_zig_version=os.environ.get("BENCH_BASELINE_ZIG_VERSION"),
                    baseline_build_mode=os.environ.get("BENCH_BASELINE_BUILD_MODE"),
                    candidate_zig_version=os.environ.get("BENCH_ZIG_VERSION"),
                    cpu_model=read_optional("/proc/cpuinfo"), architecture=platform.machine(), cpu_count=os.cpu_count(),
                    affinity=cpus, kernel=platform.release(), python=platform.python_version(), zig_version=os.environ.get("BENCH_ZIG_VERSION"),
                    rlimit_nofile=resource.getrlimit(resource.RLIMIT_NOFILE), parameters={k: v for k, v in vars(args).items() if k != "output"}, environment={})
    for path in ("/proc/sys/net/ipv4/tcp_rmem", "/proc/sys/net/ipv4/tcp_wmem", "/proc/sys/net/core/somaxconn",
                 "/proc/sys/net/ipv4/tcp_autocorking", "/proc/sys/net/ipv4/tcp_congestion_control", "/proc/sys/kernel/perf_event_paranoid",
                 "/proc/sys/net/ipv4/tcp_mem", "/proc/meminfo", "/proc/sys/fs/pipe-max-size", "/proc/sys/fs/pipe-user-pages-soft", "/proc/sys/fs/pipe-user-pages-hard",
                 "/sys/fs/cgroup/cpu.max", "/sys/fs/cgroup/cpuset.cpus.effective", "/sys/fs/cgroup/memory.max", "/sys/devices/system/node/online"):
        metadata["environment"][path] = read_optional(path)
    metadata["frequency"] = {str(cpu): {name: read_optional(f"/sys/devices/system/cpu/cpu{cpu}/cpufreq/{name}")
                                     for name in ("scaling_governor", "scaling_cur_freq")} for cpu in cpus}
    metadata["cpu_topology"] = args.cpu_topology
    capability = profiling.capabilities(args.profiling)
    metadata["perf"] = capability
    (args.output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(json.dumps(dict(event="environment", **metadata), sort_keys=True), flush=True)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with Path(os.environ["GITHUB_STEP_SUMMARY"]).open("a") as output:
            output.write("Actor affinity uses logical CPUs. Check cpu_topology and actors_sharing_visible_cores in raw data for SMT/core sharing.\n\n")
    workers_needed = max(min(args.generator_workers, n) if m in ("bulk", "loaded-latency") else 1 for m, n in args.cases)
    required_cpus = args.topology_processes + 1 + workers_needed
    if len(cpus) < required_cpus and (args.topology_processes > 1 or workers_needed > 1):
        skipped = dict(available=False, reason="insufficient distinct CPUs for proxies, origin and generator",
                       requested_proxy_processes=args.topology_processes, available_cpus=cpus)
        (args.output / "scale-out-unavailable.json").write_text(json.dumps(skipped, indent=2) + "\n")
        print(json.dumps(dict(event="scale_out", **skipped)), flush=True)
        if os.environ.get("GITHUB_STEP_SUMMARY"):
            with Path(os.environ["GITHUB_STEP_SUMMARY"]).open("a") as output:
                output.write(f"Scale-out skipped: proxies, origin and generators need {required_cpus} distinct CPUs; {len(cpus)} available.\n")
        return 0
    os.sched_setaffinity(0, {cpus[min(required_cpus, len(cpus) - 1)]})
    records = []
    try:
        for repeat in range(1, args.repeats + 1):
            for mode, count in args.cases:
                for ring in (args.rings if repeat % 2 else list(reversed(args.rings))):
                    shift = (repeat - 1) % len(args.variants)
                    variants = args.variants[shift:] + args.variants[:shift]
                    if repeat % 2 == 0:
                        variants = list(reversed(variants))
                    for variant in variants:
                        if variant != "direct" or ring == args.rings[0]:
                            records.append(trial(args, mode, count, variant, 0 if variant == "direct" else ring, repeat, capability))
        if args.profiling == "perf-record" and capability["available"]:
            mode, count = next(((m, n) for m, n in args.cases if m == "bulk" and n >= 100), ("bulk", 100))
            records.append(trial(args, mode, count, "candidate", args.rings[0], 0, capability, diagnostic=True))
    finally:
        summarize(records, args)
    return int(any(not r["passed"] for r in records))


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError, ValueError) as exc:
        print(f"benchmark: {exc}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        sys.exit(130)
