#!/usr/bin/env python3
"""Dependency-free opaque TCP echo workloads for Zigveil."""
import argparse
import asyncio
from dataclasses import dataclass, field
import json
import math
import platform
import random
import statistics
import struct
import socket
import sys
import time

# A long deterministic wire pattern, compared in C by bytes.startswith. Checking
# only byte counts would miss same-length corruption. No payload copies for sends.
PATTERN_BYTES = 1 << 20
PATTERN = random.Random(0x7A69677665696C).randbytes(PATTERN_BYTES) * 2


@dataclass
class Progress:
    tx: int = 0
    rx: int = 0
    connections: int = 0
    round_trips: int = 0
    samples: list = field(default_factory=list)
    max_inflight: int = 0
    corruption_events: int = 0


async def close_writer(writer, *, abort=False, timeout=1):
    if abort:
        writer.transport.abort()
        return
    writer.close()
    try:
        await asyncio.wait_for(writer.wait_closed(), timeout)
    except (TimeoutError, OSError):
        writer.transport.abort()
    except BaseException:
        writer.transport.abort()
        raise


def client_hello(name):
    raw = name.encode("ascii")
    entry = b"\0" + struct.pack("!H", len(raw)) + raw
    names = struct.pack("!H", len(entry)) + entry
    extension = struct.pack("!HH", 0, len(names)) + names
    body = b"\x03\x03" + bytes(32) + b"\0\0\x02\x13\x01\x01\0"
    body += struct.pack("!H", len(extension)) + extension
    handshake = b"\x01" + len(body).to_bytes(3, "big") + body
    return b"\x16\x03\x01" + struct.pack("!H", len(handshake)) + handshake


async def echo(reader, writer):
    failed = False
    try:
        while chunk := await reader.read(65536):
            writer.write(chunk)
            await writer.drain()
        if writer.can_write_eof():
            writer.write_eof()
            await writer.drain()
    except (ConnectionError, asyncio.CancelledError):
        failed = True
    finally:
        await close_writer(writer, abort=failed)


async def connect(args):
    reader, writer = await asyncio.wait_for(asyncio.open_connection(args.host, args.port), 5)
    try:
        wire = client_hello(args.sni)
        writer.write(wire)
        await writer.drain()
        if await asyncio.wait_for(reader.readexactly(len(wire)), 5) != wire:
            raise ValueError("ClientHello wire image changed")
        return reader, writer
    except BaseException:
        await close_writer(writer, abort=True)
        raise


async def bulk(pair, args, deadline, progress, drain_event=None):
    reader, writer = pair
    pattern = memoryview(PATTERN)
    credit = asyncio.Event()
    # Wake a sender waiting for echo credit when its sending window ends, even
    # if the peer stops replying. This timer is per stream, not per packet.
    wakeup = asyncio.get_running_loop().call_later(max(0, deadline - time.monotonic()), credit.set)

    async def send():
        while time.monotonic() < deadline:
            if progress.tx - progress.rx + args.chunk_bytes > args.inflight_bytes:
                credit.clear()
                await credit.wait()
                continue
            offset = progress.tx % PATTERN_BYTES
            chunk = pattern[offset:offset + args.chunk_bytes]
            writer.write(chunk)
            # Account before drain yields: the reader can already observe the
            # echo while drain is waiting. Only fully drained runs have rates.
            progress.tx += len(chunk)
            progress.max_inflight = max(progress.max_inflight, progress.tx - progress.rx)
            await writer.drain()
        if drain_event is not None:
            await drain_event.wait()
        writer.write_eof()
        await writer.drain()

    sender = asyncio.create_task(send())
    try:
        while data := await reader.read(65536):
            if not PATTERN.startswith(data, progress.rx % PATTERN_BYTES):
                progress.corruption_events += 1
                raise ValueError("bulk echo corruption")
            progress.rx += len(data)
            if progress.rx > progress.tx:
                raise ValueError("received more echo bytes than sent")
            credit.set()
        if not sender.done():
            # EOF cannot be caused by our FIN before write_eof has been issued.
            if time.monotonic() < deadline:
                raise ValueError("echo EOF before the sending window ended")
        await sender
        if progress.rx != progress.tx:
            raise ValueError(f"lost bytes: sent={progress.tx}, received={progress.rx}")
        progress.connections = 1
    finally:
        wakeup.cancel()
        if not sender.done():
            sender.cancel()
        await asyncio.gather(sender, return_exceptions=True)


async def latency(pair, args, deadline, index, progress):
    reader, writer = pair
    samples = progress.samples
    sample_cap = max(1, 1_000_000 // (1 if args.mode == "loaded-latency" else args.concurrency))
    rng = random.Random(index)
    count = 0
    payload = bytes(range(64))
    while time.monotonic() < deadline:
        start = time.perf_counter_ns()
        writer.write(payload)
        progress.tx += len(payload)
        await writer.drain()
        echoed = await reader.readexactly(len(payload))
        progress.rx += len(echoed)
        elapsed = (time.perf_counter_ns() - start) / 1000
        if echoed != payload:
            progress.corruption_events += 1
            raise ValueError("echo corruption")
        count += 1
        progress.round_trips = count
        if len(samples) < sample_cap:
            samples.append(elapsed)
        else:
            slot = rng.randrange(count)
            if slot < sample_cap:
                samples[slot] = elapsed
    progress.connections = 1


async def churn(args, deadline, progress):
    while time.monotonic() < deadline:
        _, writer = await connect(args)
        await close_writer(writer)
        progress.connections += 1
        progress.round_trips += 1


async def warmup(pair, seconds, size=65536):
    reader, writer = pair
    deadline = time.monotonic() + seconds
    payload = PATTERN[:size]
    while time.monotonic() < deadline:
        writer.write(payload)
        await writer.drain()
        if await asyncio.wait_for(reader.readexactly(len(payload)), 5) != payload:
            raise ValueError("warmup echo corruption")


class Control:
    """One inherited socket; ready/go and end/ack delimit the CPU window."""
    def __init__(self, reader, writer):
        self.reader, self.writer = reader, writer

    async def notify(self, event, **values):
        self.writer.write(json.dumps(dict(event=event, **values)).encode() + b"\n")
        await self.writer.drain()

    async def wait(self, command):
        value = json.loads(await asyncio.wait_for(self.reader.readline(), 60))
        if value.get("command") != command:
            raise ValueError(f"expected coordinator {command}, received {value}")

    @classmethod
    async def open(cls, fd):
        reader, writer = await asyncio.open_connection(sock=socket.socket(fileno=fd))
        return cls(reader, writer)


def failed_preparation(args, phase, errors):
    result = {"mode": args.mode, "concurrency": args.concurrency, "valid": False,
              "failure_phase": phase, f"{phase}_failed": True,
              "seconds": None, "measurement_window": {},
              "duration_requested_s": args.duration,
              "error_count": len(errors), "errors": list(dict.fromkeys(repr(x) for x in errors))[:16],
              "kernel": platform.release(), "python": platform.python_version()}
    for metric in ("aggregate_forwarded_gbit_s", "echo_goodput_gbit_s", "connections_per_second",
                   "round_trips_per_second", "latency_us_p50", "latency_us_p90", "latency_us_p95",
                   "latency_us_p99", "latency_us_p999", "latency_us_max", "latency_us_mean",
                   "latency_us_stddev"):
        result[metric] = None
    return result


async def run(args):
    pairs = []
    tasks = []
    clean = False
    control = None
    window_task = None
    try:
        if getattr(args, "control_fd", None) is not None:
            control = await Control.open(args.control_fd)
        if args.mode != "churn":
            semaphore = asyncio.Semaphore(16)
            async def prepare():
                async with semaphore:
                    pair = await connect(args)
                    # Retain ownership immediately, including during cancellation
                    # of a later setup task before gather has returned.
                    pairs.append(pair)
            stream_count = args.concurrency + (args.mode == "loaded-latency")
            prepared = await asyncio.gather(*(prepare() for _ in range(stream_count)), return_exceptions=True)
            errors = [x for x in prepared if isinstance(x, BaseException)]
            if errors:
                return failed_preparation(args, "setup", errors)
        warmup_seconds = getattr(args, "warmup", 0)
        if warmup_seconds:
            if args.mode == "churn":
                tasks = [asyncio.create_task(churn(args, time.monotonic() + warmup_seconds, Progress()))]
            else:
                sizes = [getattr(args, "warmup_bytes", None) or (64 if args.mode == "latency" else 65536)] * len(pairs)
                if args.mode == "loaded-latency":
                    sizes[-1] = 64
                tasks = [asyncio.create_task(warmup(pair, warmup_seconds, size))
                         for pair, size in zip(pairs, sizes)]
            try:
                await asyncio.wait_for(asyncio.gather(*tasks), warmup_seconds + 5)
            except Exception as exc:
                # The finally block cancels/joins every warmup worker before
                # closing its streams. External cancellation still propagates.
                return failed_preparation(args, "warmup", [exc])
            tasks.clear()
        progress = [Progress() for _ in range(len(pairs) if args.mode != "churn" else args.concurrency)]
        if control:
            await control.notify("ready", streams=len(pairs), warmup_s=warmup_seconds)
            await control.wait("go")
        start = time.monotonic()
        deadline = start + args.duration
        window = {}
        drain_event = asyncio.Event()

        async def window_end():
            await asyncio.sleep(max(0, deadline - time.monotonic()))
            window.update(start_ns=round(start * 1e9), end_ns=time.monotonic_ns(),
                          tx=sum(p.tx for p in progress), rx=sum(p.rx for p in progress))
            if control:
                await control.notify("window", **window)
                await control.wait("ack")
            drain_event.set()

        window_task = asyncio.create_task(window_end())
        if args.mode in ("bulk", "loaded-latency"):
            workers = [bulk(pair, args, deadline, state, drain_event) for pair, state in zip(pairs, progress)]
            if args.mode == "loaded-latency":
                workers[-1].close()
                workers[-1] = latency(pairs[-1], args, deadline, 0, progress[-1])
        elif args.mode == "latency":
            workers = [latency(pair, args, deadline, index, state)
                       for index, (pair, state) in enumerate(zip(pairs, progress))]
        else:
            workers = [churn(args, deadline, state) for state in progress]
        tasks = [asyncio.create_task(worker) for worker in workers]
        _, pending = await asyncio.wait(tasks, timeout=args.duration + args.drain_timeout)
        for task in pending:
            task.cancel()
        outcomes = await asyncio.gather(*tasks, return_exceptions=True)
        seconds = time.monotonic() - start
        await window_task
        failures = [outcome for task, outcome in zip(tasks, outcomes)
                    if task not in pending and isinstance(outcome, BaseException)]
        errors = list(dict.fromkeys(repr(x) for x in failures))[:16]
        if pending:
            errors.insert(0, f"run timed out after {args.duration + args.drain_timeout:g}s; "
                          f"{len(pending)} workers did not finish payload/EOF drain")
        clean = not errors
        tx = sum(x.tx for x in progress)
        rx = sum(x.rx for x in progress)
        connections = sum(x.connections for x in progress)
        samples = sorted(value for state in progress for value in state.samples)
        def percentile(q):
            return samples[max(0, math.ceil(len(samples) * q) - 1)] if clean and samples else None
        result = {"mode": args.mode, "concurrency": args.concurrency, "seconds": seconds,
                "measurement_window": window,
                "duration_requested_s": args.duration, "drain_seconds": max(0, seconds - args.duration),
                "drain_timeout_s": args.drain_timeout, "valid": clean, "timed_out": bool(pending),
                "inflight_bytes_per_stream": args.inflight_bytes if args.mode in ("bulk", "loaded-latency") else None,
                "max_observed_inflight_bytes_per_stream": max(x.max_inflight for x in progress) if args.mode in ("bulk", "loaded-latency") else None,
                "bytes_client_to_backend": tx, "bytes_backend_to_client": rx,
                "aggregate_forwarded_gbit_s": (tx + rx) * 8 / seconds / 1e9 if clean else None,
                "echo_goodput_gbit_s": rx * 8 / seconds / 1e9 if clean else None,
                "connections": connections,
                "completed_streams": connections,
                "failed_streams": len(failures), "unfinished_streams": len(pending),
                "corruption_events": sum(p.corruption_events for p in progress),
                "unreturned_bytes": max(0, tx - rx),
                "connections_per_second": connections / seconds if clean and args.mode == "churn" else None,
                "round_trips": sum(x.round_trips for x in progress),
                "round_trips_per_second": sum(x.round_trips for x in progress) / seconds if clean else None,
                "latency_us_p50": statistics.median(samples) if clean and samples else None,
                "latency_us_p90": percentile(.90), "latency_us_p95": percentile(.95),
                "latency_us_p99": percentile(.99),
                "latency_us_p999": percentile(.999) if len(samples) >= 10000 else None,
                "latency_us_max": samples[-1] if clean and samples else None,
                "latency_us_mean": statistics.mean(samples) if clean and samples else None,
                "latency_us_stddev": statistics.pstdev(samples) if clean and samples else None,
                "latency_sample_count": len(samples), "errors": errors,
                "error_count": len(failures) + len(pending), "unfinished_workers": len(pending),
                "kernel": platform.release(), "python": platform.python_version()}
        await asyncio.gather(*(close_writer(writer, abort=not clean) for _, writer in pairs))
        pairs.clear()
        if control:
            await control.notify("drained", valid=clean)
            await control.wait("finish")
        return result
    finally:
        if window_task is not None and not window_task.done():
            window_task.cancel()
        if window_task is not None:
            await asyncio.gather(window_task, return_exceptions=True)
        for task in tasks:
            if not task.done():
                task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        await asyncio.gather(*(close_writer(writer, abort=not clean) for _, writer in pairs))
        if control:
            await close_writer(control.writer, abort=not clean)


async def smoke():
    server = await asyncio.start_server(echo, "127.0.0.1", 0)
    async with server:
        for mode in ("bulk", "latency", "churn"):
            args = argparse.Namespace(host="127.0.0.1", port=server.sockets[0].getsockname()[1],
                                      sni="example.com", mode=mode, duration=.1, concurrency=2, chunk_bytes=4096,
                                      inflight_bytes=16384, drain_timeout=2)
            result = await run(args)
            assert not result["errors"], result
            assert result["connections"] > 0, result
            if mode == "bulk":
                assert result["bytes_client_to_backend"] == result["bytes_backend_to_client"] > 0, result
    print("benchmark harness smoke passed; no proxy performance claim")


async def serve(args):
    server = await asyncio.start_server(echo, args.host, args.port, backlog=4096)
    print(json.dumps({"event": "origin_ready", "host": args.host, "port": args.port}), flush=True)
    async with server:
        await server.serve_forever()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("smoke")
    origin = sub.add_parser("serve")
    origin.add_argument("--host", default="127.0.0.1")
    origin.add_argument("--port", type=int, default=9443)
    runner = sub.add_parser("run")
    runner.add_argument("--host", default="127.0.0.1")
    runner.add_argument("--port", type=int, default=8443)
    runner.add_argument("--sni", default="example.com")
    runner.add_argument("--mode", choices=("bulk", "latency", "churn", "loaded-latency"), default="bulk")
    runner.add_argument("--duration", type=float, default=30)
    runner.add_argument("--concurrency", type=int, default=1)
    runner.add_argument("--chunk-bytes", type=int, default=65536)
    runner.add_argument("--inflight-bytes", type=int, default=262144,
                        help="maximum unreturned bulk payload bytes per stream (default: 256 KiB)")
    runner.add_argument("--drain-timeout", type=float, default=15,
                        help="extra seconds allowed after the sending window (default: 15)")
    runner.add_argument("--warmup", type=float, default=0, help="untimed established-stream warmup seconds")
    runner.add_argument("--warmup-bytes", type=int, help="override warmup message size; default follows the workload")
    runner.add_argument("--control-fd", type=int, help="inherited coordinator socket (Linux laboratory)")
    args = parser.parse_args()
    if args.command == "serve":
        asyncio.run(serve(args))
    elif args.command == "smoke":
        asyncio.run(smoke())
    else:
        if not math.isfinite(args.duration) or args.duration <= 0 or not 1 <= args.concurrency <= 10000 or not 256 <= args.chunk_bytes <= 1048576 or args.chunk_bytes % 256:
            parser.error("duration > 0, concurrency 1..10000, chunk-bytes 256..1048576 (multiple of 256)")
        if not math.isfinite(args.drain_timeout) or args.drain_timeout <= 0:
            parser.error("drain-timeout must be finite and > 0")
        if not 256 <= args.inflight_bytes <= 67108864 or (args.mode in ("bulk", "loaded-latency") and args.inflight_bytes < args.chunk_bytes):
            parser.error("inflight-bytes must be 256..67108864 and at least chunk-bytes in bulk mode")
        if not math.isfinite(args.warmup) or not 0 <= args.warmup <= 30:
            parser.error("warmup must be finite and in 0..30 seconds")
        if args.warmup_bytes is not None and not 1 <= args.warmup_bytes <= PATTERN_BYTES:
            parser.error("warmup-bytes must be 1..1048576")
        result = asyncio.run(run(args))
        print(json.dumps(result, sort_keys=True))
        return int(bool(result["errors"]))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
