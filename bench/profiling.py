"""Optional Linux perf capabilities and gated attachment; no installation."""
import json
import os
from pathlib import Path
import re
import select
import shutil
import signal
import subprocess

EVENTS = ("task-clock", "cycles", "instructions", "branches", "branch-misses",
          "cache-references", "cache-misses", "context-switches", "cpu-migrations", "page-faults")
SYSCALLS = ("recvfrom", "sendto", "splice", "read", "pipe2", "fcntl", "epoll_wait", "epoll_pwait", "epoll_ctl", "accept4", "connect", "getsockopt", "shutdown", "close", "clock_gettime")


def parse_stat(text):
    values = {}
    unavailable = {}
    for line in text.splitlines():
        if line.startswith("#"):
            continue
        parts = line.split(";")
        if len(parts) < 3:
            continue
        try:
            values[parts[2].strip()] = float(parts[0].strip().replace(",", ""))
        except ValueError:
            unavailable[parts[2].strip()] = parts[0].strip()
    return values, unavailable


def running_percent(text):
    result = {}
    for line in text.splitlines():
        parts = line.split(";")
        if len(parts) >= 5:
            try:
                result[parts[2].strip()] = float(parts[4].strip())
            except ValueError:
                pass
    return result


def dso_split(text):
    result = dict(kernel_percent=0., user_percent=0., unknown_percent=0.)
    for line in text.splitlines():
        match = re.match(r"\s*([\d.]+)%\s+(\S+)", line)
        if match:
            overhead, dso = match.groups()
            kind = "kernel" if "kernel.kallsyms" in dso or dso.endswith(".ko") else "unknown" if dso == "[unknown]" else "user"
            result[f"{kind}_percent"] += float(overhead)
    return result if sum(result.values()) else None


def capabilities(level):
    executable = shutil.which("perf")
    result = {"available": False, "level": level, "events": {}, "command_prefix": None}
    if level == "basic" or not executable:
        result["reason"] = "profiling disabled" if level == "basic" else "perf executable is absent"
        return result
    prefixes = [[executable]]
    if shutil.which("sudo"):
        prefixes.append(["sudo", "-n", executable])
    # Permission is tested, never assumed from runner identity.
    for prefix in prefixes:
        try:
            check = subprocess.run(prefix + ["stat", "-x", ";", "-e", "task-clock", "--", "sleep", ".02"],
                                   capture_output=True, text=True, timeout=10)
        except (OSError, subprocess.TimeoutExpired) as exc:
            result["reason"] = str(exc)
            continue
        values, _ = parse_stat(check.stderr)
        if check.returncode == 0 and "task-clock" in values:
            result["command_prefix"] = prefix
            result["available"] = True
            result["reason"] = None
            break
        result["reason"] = check.stderr.strip()[-2000:]
    if not result["available"]:
        return result
    prefix = result["command_prefix"]
    for event in EVENTS + tuple(f"syscalls:sys_enter_{s}" for s in SYSCALLS):
        try:
            check = subprocess.run(prefix + ["stat", "-x", ";", "-e", event, "--", "sleep", ".02"],
                                   capture_output=True, text=True, timeout=10)
        except (OSError, subprocess.TimeoutExpired) as exc:
            result["events"][event] = dict(available=False, reason=str(exc))
            continue
        values, missing = parse_stat(check.stderr)
        result["events"][event] = {"available": check.returncode == 0 and event in values,
                                  "reason": None if check.returncode == 0 and event in values else check.stderr.strip()[-1000:]}
    return result


class Perf:
    def __init__(self, capability, pids, output, record=False):
        self.process = None
        self.output = Path(output)
        self.raw = self.output.with_suffix(".stat.txt")
        self.error = self.output.with_suffix(".perf.stderr.txt")
        self.record = record
        self.pids = pids
        self.capability = capability
        self.control = self.ack = None
        self.files = []
        if not capability["available"]:
            return
        events = [e for e, value in capability["events"].items() if value["available"]]
        if not events:
            return
        self.control_path = self.output.with_suffix(".control.fifo")
        self.ack_path = self.output.with_suffix(".ack.fifo")
        os.mkfifo(self.control_path)
        os.mkfifo(self.ack_path)
        self.control = os.open(self.control_path, os.O_RDWR | os.O_NONBLOCK)
        self.ack = os.open(self.ack_path, os.O_RDWR | os.O_NONBLOCK)
        self.enable_ok = False
        if record:
            # Recording is diagnostic only, never pooled into speed comparisons.
            event = "cycles" if capability["events"].get("cycles", {}).get("available") else "cpu-clock"
            args = ["record", "-e", event, "-F", "99", "--call-graph", "dwarf,8192", "-o", str(self.output.with_suffix(".data"))]
        else:
            args = ["stat", "-x", ";", "--no-big-num", "-o", str(self.raw), "-e", ",".join(events)]
        args += ["--delay=-1", f"--control=fifo:{self.control_path},{self.ack_path}", "-p", ",".join(map(str, pids))]
        error_log = self.error.open("w")
        self.files.append(error_log)
        try:
            self.process = subprocess.Popen(capability["command_prefix"] + args, stdout=error_log, stderr=error_log,
                                            start_new_session=True)
        except OSError as exc:
            error_log.write(str(exc))

    def gate(self, command):
        if self.process is None:
            return False
        try:
            os.write(self.control, command.encode() + b"\n")
            ready, _, _ = select.select([self.ack], [], [], 5)
            if not ready or not os.read(self.ack, 256):
                return False
            if command == "enable":
                self.enable_ok = True
            return True
        except OSError:
            return False

    def finish(self, forwarded_bytes):
        gated = self.gate("disable")
        if self.process is not None:
            try:
                os.killpg(self.process.pid, signal.SIGINT)
                self.process.wait(timeout=10)
            except (ProcessLookupError, subprocess.TimeoutExpired):
                if self.process.poll() is None:
                    os.killpg(self.process.pid, signal.SIGKILL)
                    self.process.wait(timeout=5)
        for fd in (self.control, self.ack):
            if fd is not None:
                os.close(fd)
        for file in self.files:
            file.close()
        if self.control is not None:
            self.control_path.unlink(missing_ok=True)
            self.ack_path.unlink(missing_ok=True)
        result = {"available": self.process is not None and gated and self.enable_ok, "reason": None,
                  "values": {}, "unavailable": {}, "record": self.record}
        if self.process is None or not gated:
            result["reason"] = self.error.read_text()[-2000:] if self.error.exists() else self.capability.get("reason", "perf gating failed")
        if not self.record and self.raw.exists() and result["available"]:
            result["values"], result["unavailable"] = parse_stat(self.raw.read_text())
            result["event_running_percent"] = running_percent(self.raw.read_text())
        if self.record and self.process is not None and self.output.with_suffix(".data").exists():
            report_args = self.capability["command_prefix"] + ["report", "--stdio", "--no-children", "--call-graph", "none",
                                                              "-i", str(self.output.with_suffix(".data"))]
            try:
                report = subprocess.run(report_args + ["--sort", "dso,symbol", "--percent-limit", "1"], capture_output=True, text=True, timeout=60)
                split = subprocess.run(report_args + ["--sort", "dso", "--percent-limit", "0"], capture_output=True, text=True, timeout=60)
                self.output.with_suffix(".report.txt").write_text(report.stdout + report.stderr + "\n" + split.stdout + split.stderr)
                result["sampled_kernel_user_split"] = dso_split(split.stdout) if split.returncode == 0 else None
                result["report_exit_codes"] = [report.returncode, split.returncode]
                print(json.dumps(dict(event="perf_report", report=report.stdout[:24000], errors=report.stderr[-2000:],
                                      sampled_kernel_user_split=result["sampled_kernel_user_split"])), flush=True)
            except (OSError, subprocess.TimeoutExpired) as exc:
                result["report_unavailable_reason"] = str(exc)
            data = self.output.with_suffix(".data")
            # perf record creates a private root-owned file when sudo was needed.
            # Only this owned job artifact is made readable; no host settings change.
            if "sudo" in self.capability["command_prefix"]:
                subprocess.run(["sudo", "-n", "chmod", "0644", str(data)], capture_output=True, timeout=10)
            if not os.access(data, os.R_OK):
                result["data_unavailable_reason"] = "perf.data remained unreadable after artifact permission repair"
                data.unlink()
        values = result["values"]
        cycles, instructions = values.get("cycles"), values.get("instructions")
        result["ipc"] = instructions / cycles if cycles and instructions is not None else None
        for label, value in (("cycles", cycles), ("instructions", instructions)):
            result[f"{label}_per_forwarded_byte"] = value / forwarded_bytes if value is not None and forwarded_bytes else None
            result[f"{label}_per_forwarded_gbit"] = value / (forwarded_bytes * 8 / 1e9) if value is not None and forwarded_bytes else None
        self.output.with_suffix(".perf.json").write_text(json.dumps(result, indent=2) + "\n")
        return result
