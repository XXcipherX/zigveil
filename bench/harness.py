#!/usr/bin/env python3
"""Dependency-free opaque TCP echo workloads for Zigveil."""
import argparse
import asyncio
import json
import math
import platform
import random
import statistics
import struct
import sys
import time


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
    try:
        while chunk := await reader.read(65536):
            writer.write(chunk)
            await writer.drain()
        if writer.can_write_eof():
            writer.write_eof()
            await writer.drain()
    except (ConnectionError, asyncio.CancelledError):
        pass
    finally:
        writer.close()
        try:
            await writer.wait_closed()
        except ConnectionError:
            pass


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
        writer.close()
        await writer.wait_closed()
        raise


async def bulk(pair, args, deadline):
    reader, writer = pair
    chunk = bytes(range(256)) * (args.chunk_bytes // 256)
    tx = 0

    async def send():
        nonlocal tx
        while time.monotonic() < deadline:
            writer.write(chunk)
            await writer.drain()
            tx += len(chunk)
        writer.write_eof()
        await writer.drain()

    sender = asyncio.create_task(send())
    rx = 0
    try:
        while data := await reader.read(65536):
            rx += len(data)
        await sender
        if rx != tx:
            raise ValueError(f"lost bytes: sent={tx}, received={rx}")
        return {"tx": tx, "rx": rx, "connections": 1, "samples": [], "round_trips": 0}
    finally:
        if not sender.done():
            sender.cancel()
        await asyncio.gather(sender, return_exceptions=True)
        writer.close()
        await writer.wait_closed()


async def latency(pair, args, deadline, index):
    reader, writer = pair
    samples = []
    sample_cap = max(1, 1_000_000 // args.concurrency)
    rng = random.Random(index)
    count = 0
    payload = bytes(range(64))
    try:
        while time.monotonic() < deadline:
            start = time.perf_counter_ns()
            writer.write(payload)
            await writer.drain()
            echoed = await reader.readexactly(len(payload))
            elapsed = (time.perf_counter_ns() - start) / 1000
            if echoed != payload:
                raise ValueError("echo corruption")
            count += 1
            if len(samples) < sample_cap:
                samples.append(elapsed)
            else:
                slot = rng.randrange(count)
                if slot < sample_cap:
                    samples[slot] = elapsed
        return {"tx": count * 64, "rx": count * 64, "connections": 1,
                "samples": samples, "round_trips": count}
    finally:
        writer.close()
        await writer.wait_closed()


async def churn(args, deadline):
    count = 0
    while time.monotonic() < deadline:
        _, writer = await connect(args)
        writer.close()
        await writer.wait_closed()
        count += 1
    return {"tx": 0, "rx": 0, "connections": count, "samples": [], "round_trips": count}


async def run(args):
    pairs = []
    if args.mode != "churn":
        semaphore = asyncio.Semaphore(16)
        async def prepare():
            async with semaphore:
                return await connect(args)
        prepared = await asyncio.gather(*(prepare() for _ in range(args.concurrency)), return_exceptions=True)
        errors = [repr(x) for x in prepared if isinstance(x, BaseException)]
        pairs = [x for x in prepared if not isinstance(x, BaseException)]
        if errors:
            for _, writer in pairs:
                writer.close()
                await writer.wait_closed()
            return {"errors": errors, "setup_failed": True}
    start = time.monotonic()
    deadline = start + args.duration
    if args.mode == "bulk":
        tasks = [bulk(pair, args, deadline) for pair in pairs]
    elif args.mode == "latency":
        tasks = [latency(pair, args, deadline, index) for index, pair in enumerate(pairs)]
    else:
        tasks = [churn(args, deadline) for _ in range(args.concurrency)]
    try:
        outcomes = await asyncio.wait_for(asyncio.gather(*tasks, return_exceptions=True), args.duration + 15)
    finally:
        for _, writer in pairs:
            writer.close()
            try:
                await writer.wait_closed()
            except ConnectionError:
                pass
    seconds = time.monotonic() - start
    errors = [repr(x) for x in outcomes if isinstance(x, BaseException)]
    good = [x for x in outcomes if not isinstance(x, BaseException)]
    tx = sum(x["tx"] for x in good)
    rx = sum(x["rx"] for x in good)
    connections = sum(x["connections"] for x in good)
    samples = sorted(value for result in good for value in result["samples"])
    return {"mode": args.mode, "concurrency": args.concurrency, "seconds": seconds,
            "bytes_client_to_backend": tx, "bytes_backend_to_client": rx,
            "aggregate_forwarded_gbit_s": (tx + rx) * 8 / seconds / 1e9,
            "echo_goodput_gbit_s": rx * 8 / seconds / 1e9,
            "connections": connections, "connections_per_second": connections / seconds if args.mode == "churn" else None,
            "round_trips": sum(x["round_trips"] for x in good),
            "latency_us_p50": statistics.median(samples) if samples else None,
            "latency_us_p99": samples[max(0, math.ceil(len(samples) * .99) - 1)] if samples else None,
            "latency_sample_count": len(samples), "errors": errors,
            "kernel": platform.release(), "python": platform.python_version()}


async def smoke():
    server = await asyncio.start_server(echo, "127.0.0.1", 0)
    async with server:
        for mode in ("bulk", "latency", "churn"):
            args = argparse.Namespace(host="127.0.0.1", port=server.sockets[0].getsockname()[1],
                                      sni="example.com", mode=mode, duration=.1, concurrency=2, chunk_bytes=4096)
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
    args = parser.parse_args()
    if args.command == "serve":
        asyncio.run(serve(args))
    elif args.command == "smoke":
        asyncio.run(smoke())
    else:
        if args.duration <= 0 or not 1 <= args.concurrency <= 10000 or not 256 <= args.chunk_bytes <= 1048576 or args.chunk_bytes % 256:
            parser.error("duration > 0, concurrency 1..10000, chunk-bytes 256..1048576 (multiple of 256)")
        result = asyncio.run(run(args))
        print(json.dumps(result, sort_keys=True))
        return int(bool(result["errors"]))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        pass
