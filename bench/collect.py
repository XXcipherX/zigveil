#!/usr/bin/env python3
"""Sample Linux /proc for one or more externally launched proxy processes."""
import argparse
import json
import os
import platform
import time
from pathlib import Path


def cpu_topology(cpus):
    topology = {}
    for cpu in cpus:
        values = {}
        for name in ("physical_package_id", "core_id", "thread_siblings_list"):
            try:
                values[name] = Path(f"/sys/devices/system/cpu/cpu{cpu}/topology/{name}").read_text().strip()
            except OSError:
                values[name] = None
        topology[str(cpu)] = values
    return topology


def snapshot(pid):
    root = Path(f"/proc/{pid}")
    stat = (root / "stat").read_text()
    fields = stat[stat.rfind(")") + 2:].split()
    status = dict(line.split(":", 1) for line in (root / "status").read_text().splitlines())
    sched = {}
    try:
        sched = dict(line.split(":", 1) for line in (root / "sched").read_text().splitlines() if ":" in line)
        sched = {k.strip(): v.strip() for k, v in sched.items()}
    except OSError:
        pass
    try:
        runtime_ns, runqueue_ns, timeslices = map(int, (root / "schedstat").read_text().split()[:3])
    except OSError:
        runtime_ns = runqueue_ns = timeslices = None
    return {"sample_ns": time.monotonic_ns(), "user_ticks": int(fields[11]), "system_ticks": int(fields[12]),
            "minor_faults": int(fields[7]), "major_faults": int(fields[9]),
            "runtime_ns": runtime_ns, "runqueue_ns": runqueue_ns, "timeslices": timeslices,
            "cpu_migrations": int(sched["se.nr_migrations"]) if "se.nr_migrations" in sched else None,
            "rss_bytes": int(status["VmRSS"].split()[0]) * 1024,
            "hwm_rss_bytes": int(status["VmHWM"].split()[0]) * 1024,
            "virtual_bytes": int(status["VmSize"].split()[0]) * 1024,
            "voluntary_switches": int(status["voluntary_ctxt_switches"]),
            "involuntary_switches": int(status["nonvoluntary_ctxt_switches"]),
            "threads": int(status["Threads"]), "fds": len(list((root / "fd").iterdir()))}


def difference(before, after, forwarded_bytes=None, peak_rss=None):
    seconds = (after["sample_ns"] - before["sample_ns"]) / 1e9
    hz = os.sysconf("SC_CLK_TCK")
    user = (after["user_ticks"] - before["user_ticks"]) / hz
    system = (after["system_ticks"] - before["system_ticks"]) / hz
    runtime = ((after["runtime_ns"] - before["runtime_ns"]) / 1e9
               if after["runtime_ns"] is not None and before["runtime_ns"] is not None else None)
    cpu = runtime if runtime is not None else user + system
    result = {"seconds": seconds, "user_cpu_seconds": user, "system_cpu_seconds": system,
              "cpu_seconds": cpu, "cpu_source": "schedstat" if runtime is not None else "stat_ticks",
              "cpu_percent_one_core": cpu / seconds * 100 if seconds else None,
              "cpu_seconds_per_forwarded_gbit": cpu / (forwarded_bytes * 8 / 1e9) if forwarded_bytes else None,
              "rss_bytes": after["rss_bytes"], "virtual_bytes": after["virtual_bytes"],
              "peak_sampled_rss_bytes": peak_rss if peak_rss is not None else max(before["rss_bytes"], after["rss_bytes"]),
              "process_lifetime_peak_rss_bytes": after["hwm_rss_bytes"],
              "threads": after["threads"], "fds": after["fds"]}
    for key in ("voluntary_switches", "involuntary_switches", "minor_faults", "major_faults", "cpu_migrations", "runqueue_ns", "timeslices"):
        result[key] = after[key] - before[key] if before[key] is not None and after[key] is not None else None
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", type=int, action="append", required=True)
    parser.add_argument("--duration", type=float, default=30)
    parser.add_argument("--active-connections", type=int)
    parser.add_argument("--forwarded-bytes", type=int)
    parser.add_argument("--cycles", type=int)
    parser.add_argument("--syscalls", type=int)
    args = parser.parse_args()
    if args.duration < 0 or any(pid <= 0 for pid in args.pid) or len(args.pid) > 64:
        parser.error("duration >= 0 and 1..64 positive process IDs required")
    before = [snapshot(pid) for pid in args.pid]
    start = time.monotonic()
    deadline = start + args.duration
    peak_rss = sum(x["rss_bytes"] for x in before)
    after = before
    while time.monotonic() < deadline:
        time.sleep(min(.1, max(0, deadline - time.monotonic())))
        after = [snapshot(pid) for pid in args.pid]
        peak_rss = max(peak_rss, sum(x["rss_bytes"] for x in after))
    hz = os.sysconf("SC_CLK_TCK")
    cpu_seconds = sum((b["user_ticks"] + b["system_ticks"] - a["user_ticks"] - a["system_ticks"]) / hz
                      for a, b in zip(before, after))
    rss = sum(x["rss_bytes"] for x in after)
    result = {"pids": args.pid, "seconds": time.monotonic() - start, "cpu_seconds": cpu_seconds,
              "rss_bytes": rss, "peak_rss_bytes": peak_rss,
              "virtual_bytes": sum(x["virtual_bytes"] for x in after),
              "fds": sum(x["fds"] for x in after), "threads": sum(x["threads"] for x in after),
              "context_switches": sum(b["voluntary_switches"] + b["involuntary_switches"] -
                                      a["voluntary_switches"] - a["involuntary_switches"] for a, b in zip(before, after)),
              "rss_bytes_per_active_connection": rss / args.active_connections if args.active_connections else None,
              "kernel": platform.release()}
    if args.forwarded_bytes:
        result["cpu_seconds_per_forwarded_gbit"] = cpu_seconds / (args.forwarded_bytes * 8 / 1e9)
        if args.cycles is not None:
            result["cycles_per_forwarded_byte"] = args.cycles / args.forwarded_bytes
        if args.syscalls is not None:
            result["syscalls_per_forwarded_gib"] = args.syscalls / (args.forwarded_bytes / 1024 ** 3)
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
