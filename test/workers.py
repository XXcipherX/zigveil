#!/usr/bin/env python3
"""Focused Linux checks of the production multi-worker runtime."""
import argparse
import concurrent.futures
import contextlib
import json
import os
import re
import signal
import socket
import subprocess
import tempfile
import unittest
from pathlib import Path

import integration as base

SingleDaemon = base.Daemon


class WorkerDaemon(SingleDaemon):
    def __init__(self, backend, **options):
        options.setdefault("workers", 2)
        # A reused one-slot fixture becomes one slot per worker; zero local
        # capacity is invalid, and the same byte/lifetime contract is exercised.
        for key in ("max_connections", "max_handshakes"):
            if key in options:
                options[key] = max(options[key], options["workers"])
        super().__init__(backend, **options)
        self.wait_for(lambda: listener_count(self) == self.config["workers"])


def listener_count(daemon):
    try:
        return len(set(base.listening_inodes(daemon.process.pid, daemon.port)))
    except FileNotFoundError:
        return 0


def worker_snapshots(daemon):
    old = len([e for e in daemon.events() if e.get("event") == "worker_stats"])
    counts = daemon.snapshot()
    daemon.wait_for(lambda: len([e for e in daemon.events() if e.get("event") == "worker_stats"])
                    >= old + daemon.config["workers"])
    records = [e for e in daemon.events() if e.get("event") == "worker_stats"][old:]
    return counts, [{key: int(value) for key, value in re.findall(r"(\w+)=(\d+)", e["message"])}
                    for e in records[:daemon.config["workers"]]]


class Workers(unittest.TestCase):
    def test_multiple_listeners_route_on_distinct_workers_and_aggregate_bytes(self):
        with base.Origin() as origin, WorkerDaemon(origin.address, max_connections=67, max_handshakes=35,
                                                   log_level="debug", relay_buffer_bytes=65536) as daemon:
            def transfer(index):
                with daemon.connect() as client:
                    wire = base.hello(padding=24000) + bytes([index]) * 65536
                    client.sendall(wire)
                    client.shutdown(socket.SHUT_WR)
                    self.assertEqual(wire, base.all_bytes(client))
                    return len(wire)
            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
                byte_count = sum(executor.map(transfer, range(32)))
            daemon.wait_for(lambda: len([e for e in daemon.events() if e.get("event") == "connection_closed"]) == 32)
            counts, workers = worker_snapshots(daemon)
            self.assertEqual(0, counts["active"])
            self.assertEqual(32, counts["routed"])
            self.assertEqual(byte_count, counts["bytes_client_to_backend"])
            self.assertEqual(byte_count, counts["bytes_backend_to_client"])
            self.assertEqual({0, 1}, {w["worker"] for w in workers if w["routed"]})
            self.assertEqual(counts["accepted"], sum(w["accepted"] for w in workers))
            self.assertEqual(counts["closed"], sum(w["closed"] for w in workers))
            closed = [e for e in daemon.events() if e.get("event") == "connection_closed"]
            self.assertEqual({0, 1}, {e["worker"] for e in closed})
            children = Path(f"/proc/{daemon.process.pid}/task/{daemon.process.pid}/children").read_text().strip()
            self.assertEqual("", children)

    def test_unequal_capacity_and_handshake_limits_are_global(self):
        with base.Origin() as origin, WorkerDaemon(origin.address, workers=3, max_connections=9,
                                                   max_handshakes=5, log_level="none") as daemon:
            with contextlib.ExitStack() as stack:
                clients = [stack.enter_context(daemon.connect()) for _ in range(24)]
                # Empty hellos retain staging until shutdown. Local imbalance
                # can reduce utilization but may never exceed the total ceiling.
                daemon.wait_for(lambda: sum(w["accepted"] for w in worker_snapshots(daemon)[1]) >= len(clients))
                counts, workers = worker_snapshots(daemon)
                self.assertLessEqual(counts["active"], 5)
                self.assertGreater(counts["rejected"], 0)
                self.assertEqual(counts["active"], sum(w["active"] for w in workers))

    def test_log_level_switch_acknowledges_all_workers_and_muted_snapshots(self):
        with base.Origin() as origin, WorkerDaemon(origin.address, log_level="info") as daemon:
            daemon.process.send_signal(signal.SIGUSR2)
            daemon.wait_for(lambda: any(e.get("event") == "log_level" and "debug" in e["message"] for e in daemon.events()))
            for _ in range(16):
                with daemon.connect() as client:
                    wire = base.hello()
                    client.sendall(wire)
                    client.shutdown(socket.SHUT_WR)
                    self.assertEqual(wire, base.all_bytes(client))
            daemon.wait_for(lambda: len([e for e in daemon.events() if e.get("event") == "connection_closed"]) == 16)
            daemon.process.send_signal(signal.SIGUSR2)
            daemon.wait_for(lambda: any(e.get("event") == "log_level" and "none" in e["message"] for e in daemon.events()))
            old = len([e for e in daemon.events() if e.get("event") == "connection_closed"])
            for _ in range(8):
                with daemon.connect() as client:
                    wire = base.hello()
                    client.sendall(wire)
                    client.shutdown(socket.SHUT_WR)
                    self.assertEqual(wire, base.all_bytes(client))
            counts, workers = worker_snapshots(daemon)
            self.assertEqual(24, counts["routed"])
            self.assertEqual(old, len([e for e in daemon.events() if e.get("event") == "connection_closed"]))
            self.assertEqual({0, 1}, {w["worker"] for w in workers})
            for expected in ("error", "warn", "info"):
                daemon.process.send_signal(signal.SIGUSR2)
                daemon.wait_for(lambda: any(e.get("event") == "log_level" and f"to {expected}" in e["message"]
                                           for e in daemon.events()))

    def test_connection_capacity_is_not_cloned_after_staging_is_released(self):
        with base.Origin() as origin, WorkerDaemon(origin.address, max_connections=5, max_handshakes=5,
                                                   log_level="none") as daemon:
            with contextlib.ExitStack() as stack:
                admitted = []
                for _ in range(20):
                    client = stack.enter_context(daemon.connect())
                    wire = base.hello()
                    try:
                        client.sendall(wire)
                        self.assertEqual(wire, base.exact(client, len(wire)))
                    except (ConnectionResetError, BrokenPipeError):
                        continue
                    except AssertionError as error:
                        if "early EOF" not in str(error):
                            raise
                        continue
                    admitted.append(client)
                counts, workers = worker_snapshots(daemon)
                self.assertGreater(len(admitted), 0)
                self.assertLessEqual(len(admitted), 5)
                self.assertEqual(len(admitted), counts["active"])
                self.assertEqual(counts["active"], sum(w["active"] for w in workers))
                self.assertGreater(counts["rejected"], 0)

    def test_signal_stops_hello_and_relay_workers_and_releases_port(self):
        for stop in (signal.SIGTERM, signal.SIGINT):
            with self.subTest(signal=stop), base.Origin() as origin:
                with WorkerDaemon(origin.address, log_level="debug") as daemon:
                    with contextlib.ExitStack() as stack:
                        clients = [stack.enter_context(daemon.connect()) for _ in range(8)]
                        for client in clients[:4]:
                            wire = base.hello() + b"live"
                            client.sendall(wire)
                            self.assertEqual(wire, base.exact(client, len(wire)))
                        counts, _ = worker_snapshots(daemon)
                        self.assertEqual(8, counts["active"])
                        with daemon.paused():
                            daemon.process.send_signal(stop)
                            daemon.process.send_signal(signal.SIGINT if stop == signal.SIGTERM else signal.SIGTERM)
                        daemon.process.wait(timeout=5)
                        self.assertEqual(0, daemon.process.returncode, daemon.logs())
                        for client in clients:
                            try:
                                self.assertEqual(b"", client.recv(1))
                            except ConnectionResetError:
                                pass
                        self.assertEqual(0, listener_count(daemon))
                        self.assertEqual(1, len([e for e in daemon.events() if e.get("event") == "stopped"]))
                        final = [e for e in daemon.events() if e.get("event") == "stats"][-1]
                        self.assertEqual(0, final["active"])
                        self.assertEqual(8, final["accepted"])
                        self.assertEqual(8, final["closed"])
                        self.assertEqual(0, final["io_errors"])
                        port = daemon.port
                with socket.socket() as sock:
                    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                    sock.bind(("127.0.0.1", port))

    def test_idle_shutdown_and_sixteen_workers(self):
        with base.Origin() as origin, WorkerDaemon(origin.address, workers=16, max_connections=32,
                                                   max_handshakes=16, log_level="none") as daemon:
            counts, workers = worker_snapshots(daemon)
            self.assertEqual(16, len(workers))
            self.assertEqual(0, counts["active"])

    def test_invalid_workers_and_aggregate_fd_requirement(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            config = {"listen": f"127.0.0.1:{base.free_port()}", "routes": [], "fallback": "127.0.0.1:1",
                      "max_connections": 32, "max_handshakes": 16}
            for workers in (0, 17, -1, 2.5):
                config["workers"] = workers
                path.write_text(json.dumps(config), encoding="utf-8")
                result = subprocess.run([base.BINARY, "--check", str(path)], capture_output=True, text=True, timeout=5)
                self.assertNotEqual(0, result.returncode)
            config.update(workers=2, max_connections=8, max_handshakes=4)
            path.write_text(json.dumps(config), encoding="utf-8")
            # 28 supports the former single-owner requirement, but not two
            # workers' complete listener/epoll/eventfd/pipe reservation.
            result = subprocess.run(["prlimit", "--nofile=28:28", base.BINARY, "--check", str(path)],
                                    capture_output=True, text=True, timeout=5)
            self.assertNotEqual(0, result.returncode, result.stderr)
            self.assertIn("RLIMIT_NOFILE", result.stderr)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True)
    parser.add_argument("--buffered", action="store_true")
    parser.add_argument("--diagnostics", action="store_true")
    parser.add_argument("--tsan", action="store_true", help="expect the ThreadSanitizer runtime's background thread")
    args = parser.parse_args()
    base.BINARY = str(Path(args.binary).resolve())
    base.SPLICE = not args.buffered
    base.DIAGNOSTICS = args.diagnostics
    base.SANITIZER_THREADS = 1 if args.tsan else 0
    base.Daemon = WorkerDaemon
    # Reuse real protocol/FIN/pressure checks without copying their harness.
    selected = (
        "test_byte_preservation_fragmentation_and_large_pq_shaped_prefix",
        "test_unknown_missing_invalid_and_fallback",
        "test_fallback_proxy_v2_exact_socket_addresses_and_reused_slots",
        "test_known_route_never_receives_fallback_proxy_header",
        "test_optional_tcp_liveness_preserves_prefix_bulk_and_fin",
        "test_client_half_close_then_backend_reply",
        "test_backend_half_close_then_client_continues",
        "test_full_duplex_bulk_and_slow_consumer",
        "test_client_rst_has_exact_socket_side_and_errno_dimensions",
        "test_backend_rst_has_exact_socket_side_and_errno_dimensions",
        "test_real_tls_passthrough_and_ipv6_backend",
        "test_real_tls_fallback_after_proxy_v2_and_raw_known_route",
    )
    suite = unittest.TestSuite(base.Integration(name) for name in selected)
    suite.addTests(unittest.defaultTestLoader.loadTestsFromTestCase(Workers))
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    raise SystemExit(not result.wasSuccessful())
