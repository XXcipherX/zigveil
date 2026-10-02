#!/usr/bin/env python3
"""Sample Linux /proc for one or more externally launched proxy processes."""
import argparse
import json
import os
import platform
import time
from pathlib import Path


def snapshot(pid):
    root = Path(f"/proc/{pid}")
    stat = (root / "stat").read_text()
    fields = stat[stat.rfind(")") + 2:].split()
    status = dict(line.split(":", 1) for line in (root / "status").read_text().splitlines())
    return {"user_ticks": int(fields[11]), "system_ticks": int(fields[12]),
            "rss_bytes": int(status["VmRSS"].split()[0]) * 1024,
            "virtual_bytes": int(status["VmSize"].split()[0]) * 1024,
            "voluntary_switches": int(status["voluntary_ctxt_switches"]),
            "involuntary_switches": int(status["nonvoluntary_ctxt_switches"]),
            "threads": int(status["Threads"]), "fds": len(list((root / "fd").iterdir()))}


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
