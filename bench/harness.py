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
import sys
import time


@dataclass
class Progress:
    tx: int = 0
    rx: int = 0
    connections: int = 0
    round_trips: int = 0
    samples: list = field(default_factory=list)
    max_inflight: int = 0


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


async def bulk(pair, args, deadline, progress):
    reader, writer = pair
    chunk = bytes(range(256)) * (args.chunk_bytes // 256)
    credit = asyncio.Event()
    # Wake a sender waiting for echo credit when its sending window ends, even
    # if the peer stops replying. This timer is per stream, not per packet.
    wakeup = asyncio.get_running_loop().call_later(max(0, deadline - time.monotonic()), credit.set)

    async def send():
        while time.monotonic() < deadline:
            if progress.tx - progress.rx + len(chunk) > args.inflight_bytes:
                credit.clear()
                await credit.wait()
                continue
            writer.write(chunk)
            # Account before drain yields: the reader can already observe the
            # echo while drain is waiting. Only fully drained runs have rates.
            progress.tx += len(chunk)
            progress.max_inflight = max(progress.max_inflight, progress.tx - progress.rx)
            await writer.drain()
        writer.write_eof()
        await writer.drain()

    sender = asyncio.create_task(send())
    try:
        while data := await reader.read(65536):
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
    sample_cap = max(1, 1_000_000 // args.concurrency)
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


async def run(args):
    pairs = []
    tasks = []
    clean = False
    try:
        if args.mode != "churn":
            semaphore = asyncio.Semaphore(16)
            async def prepare():
                async with semaphore:
                    pair = await connect(args)
                    # Retain ownership immediately, including during cancellation
                    # of a later setup task before gather has returned.
                    pairs.append(pair)
            prepared = await asyncio.gather(*(prepare() for _ in range(args.concurrency)), return_exceptions=True)
            errors = [repr(x) for x in prepared if isinstance(x, BaseException)]
            if errors:
                return {"mode": args.mode, "concurrency": args.concurrency,
                        "valid": False, "setup_failed": True, "error_count": len(errors),
                        "errors": list(dict.fromkeys(errors))[:16]}
        progress = [Progress() for _ in range(args.concurrency)]
        start = time.monotonic()
        deadline = start + args.duration
        if args.mode == "bulk":
            workers = [bulk(pair, args, deadline, state) for pair, state in zip(pairs, progress)]
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
        return {"mode": args.mode, "concurrency": args.concurrency, "seconds": seconds,
                "duration_requested_s": args.duration, "drain_seconds": max(0, seconds - args.duration),
                "drain_timeout_s": args.drain_timeout, "valid": clean, "timed_out": bool(pending),
                "inflight_bytes_per_stream": args.inflight_bytes if args.mode == "bulk" else None,
                "max_observed_inflight_bytes_per_stream": max(x.max_inflight for x in progress) if args.mode == "bulk" else None,
                "bytes_client_to_backend": tx, "bytes_backend_to_client": rx,
                "aggregate_forwarded_gbit_s": (tx + rx) * 8 / seconds / 1e9 if clean else None,
                "echo_goodput_gbit_s": rx * 8 / seconds / 1e9 if clean else None,
                "connections": connections,
                "connections_per_second": connections / seconds if clean and args.mode == "churn" else None,
                "round_trips": sum(x.round_trips for x in progress),
                "latency_us_p50": statistics.median(samples) if clean and samples else None,
                "latency_us_p99": samples[max(0, math.ceil(len(samples) * .99) - 1)] if clean and samples else None,
                "latency_sample_count": len(samples), "errors": errors,
                "error_count": len(failures) + len(pending), "unfinished_workers": len(pending),
                "kernel": platform.release(), "python": platform.python_version()}
    finally:
        for task in tasks:
            if not task.done():
                task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        await asyncio.gather(*(close_writer(writer, abort=not clean) for _, writer in pairs))


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
    runner.add_argument("--mode", choices=("bulk", "latency", "churn"), default="bulk")
    runner.add_argument("--duration", type=float, default=30)
    runner.add_argument("--concurrency", type=int, default=1)
    runner.add_argument("--chunk-bytes", type=int, default=65536)
    runner.add_argument("--inflight-bytes", type=int, default=262144,
                        help="maximum unreturned bulk payload bytes per stream (default: 256 KiB)")
    runner.add_argument("--drain-timeout", type=float, default=15,
                        help="extra seconds allowed after the sending window (default: 15)")
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
        if not 256 <= args.inflight_bytes <= 67108864 or (args.mode == "bulk" and args.inflight_bytes < args.chunk_bytes):
            parser.error("inflight-bytes must be 256..67108864 and at least chunk-bytes in bulk mode")
        result = asyncio.run(run(args))
        print(json.dumps(result, sort_keys=True))
        return int(bool(result["errors"]))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
