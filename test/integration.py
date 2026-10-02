#!/usr/bin/env python3
"""Linux integration tests for the daemon, sockets and connection lifecycle."""
import argparse
import contextlib
import json
import os
import resource
import signal
import socket
import ssl
import struct
import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path

BINARY = "zig-out/bin/zigveil"
IO_OPERATIONS = ("client_read_errors", "client_write_errors", "backend_read_errors", "backend_write_errors",
                 "client_shutdown_errors", "backend_shutdown_errors", "client_socket_errors", "backend_socket_errors")
IO_CAUSES = ("connection_resets", "broken_pipes", "not_connected", "connection_aborts",
             "socket_timeouts", "network_errors", "other_io_errors", "zero_writes")


def hello(name="example.com", fragment=16384, padding=0):
    extension = b""
    if name is not None:
        raw = name.encode("ascii")
        entry = b"\0" + struct.pack("!H", len(raw)) + raw
        value = struct.pack("!H", len(entry)) + entry
        extension = struct.pack("!HH", 0, len(value)) + value
    if padding:
        extension += struct.pack("!HH", 21, padding) + bytes(padding)
    body = b"\x03\x03" + bytes(32) + b"\0\0\x02\x13\x01\x01\0"
    body += struct.pack("!H", len(extension)) + extension
    handshake = b"\x01" + len(body).to_bytes(3, "big") + body
    return b"".join(b"\x16\x03\x01" + struct.pack("!H", len(part)) + part
                    for part in (handshake[p:p + fragment] for p in range(0, len(handshake), fragment)))


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def exact(sock, count):
    result = bytearray()
    while len(result) < count:
        chunk = sock.recv(count - len(result))
        if not chunk:
            raise AssertionError(f"early EOF at {len(result)}/{count}")
        result.extend(chunk)
    return bytes(result)


def all_bytes(sock):
    result = bytearray()
    while True:
        chunk = sock.recv(65536)
        if not chunk:
            return bytes(result)
        result.extend(chunk)


def echo(sock):
    while True:
        chunk = sock.recv(4096)
        if not chunk:
            return
        sock.sendall(chunk)


class Origin:
    def __init__(self, handler=echo, ipv6=False):
        self.handler = handler
        self.errors = []
        self.workers = []
        self.stopped = threading.Event()
        self.socket = socket.socket(socket.AF_INET6 if ipv6 else socket.AF_INET, socket.SOCK_STREAM)
        self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.socket.bind(("::1" if ipv6 else "127.0.0.1", 0))
        self.port = self.socket.getsockname()[1]
        self.address = f"[::1]:{self.port}" if ipv6 else f"127.0.0.1:{self.port}"
        self.socket.listen(128)
        self.socket.settimeout(0.1)
        self.thread = threading.Thread(target=self.accept, daemon=True)
        self.thread.start()

    def accept(self):
        while not self.stopped.is_set():
            try:
                conn, _ = self.socket.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            worker = threading.Thread(target=self.serve, args=(conn,), daemon=True)
            self.workers.append(worker)
            worker.start()

    def serve(self, conn):
        with conn:
            conn.settimeout(5)
            try:
                self.handler(conn)
            except (BrokenPipeError, ConnectionResetError):
                pass
            except Exception as exc:
                self.errors.append(exc)

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.stopped.set()
        self.socket.close()
        self.thread.join(timeout=2)
        deadline = time.monotonic() + 5
        for worker in self.workers:
            worker.join(timeout=max(0, deadline - time.monotonic()))
        if self.thread.is_alive() or any(worker.is_alive() for worker in self.workers):
            raise AssertionError("origin threads failed to drain")
        if self.errors:
            raise AssertionError(self.errors)


class Daemon:
    def __init__(self, backend, launch_prefix=(), **overrides):
        self.directory = tempfile.TemporaryDirectory()
        self.port = free_port()
        self.config = {"listen": f"127.0.0.1:{self.port}",
                       "routes": [{"sni": "example.com", "backend": backend}],
                       "max_connections": 32, "max_handshakes": 16,
                       "relay_buffer_bytes": 4096, "stats_interval_ms": 0,
                       "log_format": "json"}
        self.config.update(overrides)
        self.port = int(self.config["listen"].rsplit(":", 1)[1])
        if self.config.get("log_format") is None:
            self.config.pop("log_format", None)
        path = Path(self.directory.name) / "config.json"
        path.write_text(json.dumps(self.config), encoding="utf-8")
        self.log_path = Path(self.directory.name) / "stderr.log"
        self.log_file = self.log_path.open("wb")
        self.process = subprocess.Popen([*launch_prefix, BINARY, str(path)], stderr=self.log_file)
        # Read kernel listener state without opening a probe connection or relying
        # on INFO output; warn/error/none must start silently too.
        try:
            self.wait_for(self.listening)
        except BaseException:
            if self.process.poll() is None:
                self.process.terminate()
                try:
                    self.process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait(timeout=2)
            self.log_file.close()
            self.directory.cleanup()
            raise

    def listening(self):
        inodes = set()
        try:
            for fd in Path(f"/proc/{self.process.pid}/fd").iterdir():
                try:
                    target = os.readlink(fd)
                except FileNotFoundError:
                    continue
                if target.startswith("socket:["):
                    inodes.add(target[8:-1])
            for table in ("tcp", "tcp6"):
                for line in Path(f"/proc/{self.process.pid}/net/{table}").read_text().splitlines()[1:]:
                    fields = line.split()
                    if fields[3] == "0A" and int(fields[1].split(":")[1], 16) == self.port and fields[9] in inodes:
                        return True
        except FileNotFoundError:
            pass
        return False

    def logs(self):
        return self.log_path.read_text(encoding="utf-8")

    def events(self):
        # A concurrent regular-file read can see the tail of an unfinished
        # write. Only newline-terminated records are ready for JSON parsing;
        # malformed complete records must still fail the test.
        return [json.loads(line) for line in self.logs().splitlines(keepends=True)
                if line.startswith("{") and line.endswith("\n")]

    def wait_for(self, predicate, timeout=5):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return
            if self.process.poll() is not None:
                raise AssertionError(f"daemon exited: {self.logs()}")
            time.sleep(0.01)
        raise AssertionError(f"condition timed out: {self.logs()}")

    def connect(self):
        sock = socket.create_connection(("127.0.0.1", self.port), timeout=5)
        sock.settimeout(5)
        return sock

    def snapshot(self):
        def snapshots():
            return [event for event in self.events() if event.get("event") == "stats"]
        old = len(snapshots())
        self.process.send_signal(signal.SIGUSR1)
        self.wait_for(lambda: len(snapshots()) > old)
        return snapshots()[-1]

    @contextlib.contextmanager
    def paused(self):
        # Queue RST before epoll resumes, instead of racing a read/send handler.
        self.process.send_signal(signal.SIGSTOP)
        try:
            self.wait_for(lambda: "State:\tT" in Path(f"/proc/{self.process.pid}/status").read_text())
            yield
        finally:
            if self.process.poll() is None:
                self.process.send_signal(signal.SIGCONT)

    def __enter__(self):
        return self

    def __exit__(self, *_):
        try:
            if self.process.poll() is None:
                self.process.send_signal(signal.SIGTERM)
                try:
                    self.process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self.process.send_signal(signal.SIGTERM)
                    self.process.wait(timeout=2)
                    raise AssertionError(f"graceful drain stalled: {self.logs()}")
            if self.process.returncode != 0:
                raise AssertionError(self.logs())
        finally:
            self.log_file.close()
            self.directory.cleanup()


class Integration(unittest.TestCase):
    def assert_io_dimensions(self, counts, total=None):
        self.assertEqual(counts["io_errors"], sum(counts[name] for name in IO_OPERATIONS))
        self.assertEqual(counts["io_errors"], sum(counts[name] for name in IO_CAUSES))
        if total is not None:
            self.assertEqual(total, counts["io_errors"])

    def assert_clean_drain(self, proxy):
        proxy.wait_for(lambda: proxy.snapshot()["active"] == 0)
        self.assert_io_dimensions(proxy.snapshot(), 0)

    def assert_closed(self, sock):
        try:
            self.assertEqual(b"", sock.recv(1))
        except ConnectionResetError:
            pass

    def test_byte_preservation_fragmentation_and_large_pq_shaped_prefix(self):
        with Origin() as origin, Daemon(origin.address) as proxy:
            for fragment in (16384, 2, 1000):
                # Two-byte records require a small hello to stay within 64 records.
                wire = hello("ExAmPle.COM", fragment, 0 if fragment == 2 else 24000)
                payload = wire + b"coalesced-extra" + bytes(range(256)) * 32
                with proxy.connect() as client:
                    if fragment == 2:
                        for p in range(0, len(wire), 7):
                            client.sendall(wire[p:p + 7])
                        client.sendall(payload[len(wire):])
                    else:
                        client.sendall(payload)
                    client.shutdown(socket.SHUT_WR)
                    self.assertEqual(payload, all_bytes(client))
            self.assertEqual(1, len(os.listdir(f"/proc/{proxy.process.pid}/task")))

    def test_unknown_missing_invalid_and_fallback(self):
        with Origin() as origin:
            with Daemon(origin.address) as proxy:
                for wire in (hello("unknown.example.com"), hello(None), b"not TLS", b"\x16\x03\x01\xff\xff", hello(fragment=1)):
                    with proxy.connect() as client:
                        client.sendall(wire)
                        self.assert_closed(client)
                counts = proxy.snapshot()
                self.assertEqual(1, counts["unknown_sni"])
                self.assertEqual(1, counts["missing_sni"])
                self.assertGreaterEqual(counts["invalid_client_hello"], 3)
            with Daemon(origin.address, fallback=origin.address) as proxy:
                with proxy.connect() as client:
                    wire = hello("unknown.example.com") + b"opaque"
                    client.sendall(wire)
                    self.assertEqual(wire, exact(client, len(wire)))

    def test_client_half_close_then_backend_reply(self):
        received = []

        def after_fin(sock):
            received.append(all_bytes(sock))
            sock.sendall(b"reply after FIN")
            sock.shutdown(socket.SHUT_WR)

        with Origin(after_fin) as origin, Daemon(origin.address) as proxy:
            with proxy.connect() as client:
                wire = hello() + os.urandom(300000)
                client.sendall(wire)
                client.shutdown(socket.SHUT_WR)
                self.assertEqual(b"reply after FIN", all_bytes(client))
            self.assertEqual([wire], received)
            self.assert_clean_drain(proxy)

    def test_backend_half_close_then_client_continues(self):
        received = []
        done = threading.Event()

        def early_fin(sock):
            sock.sendall(b"server done")
            sock.shutdown(socket.SHUT_WR)
            received.append(all_bytes(sock))
            done.set()

        with Origin(early_fin) as origin, Daemon(origin.address) as proxy:
            with proxy.connect() as client:
                wire = hello()
                client.sendall(wire)
                self.assertEqual(b"server done", all_bytes(client))
                tail = os.urandom(70000)
                client.sendall(tail)
                client.shutdown(socket.SHUT_WR)
                self.assertTrue(done.wait(5))
            self.assertEqual([wire + tail], received)
            self.assert_clean_drain(proxy)

    def test_full_duplex_bulk_and_slow_consumer(self):
        received = []
        upload = hello() + os.urandom(2 * 1024 * 1024)
        download = os.urandom(2 * 1024 * 1024)
        sender_errors = []
        done = threading.Event()

        def duplex(sock):
            def send():
                try:
                    sock.sendall(download)
                    sock.shutdown(socket.SHUT_WR)
                except Exception as exc:
                    sender_errors.append(exc)
            sender = threading.Thread(target=send)
            sender.start()
            received.append(all_bytes(sock))
            sender.join(timeout=5)
            done.set()

        with Origin(duplex) as origin, Daemon(origin.address) as proxy:
            with proxy.connect() as client:
                client.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 32768)
                def send():
                    try:
                        client.sendall(upload)
                        client.shutdown(socket.SHUT_WR)
                    except Exception as exc:
                        sender_errors.append(exc)
                sender = threading.Thread(target=send)
                sender.start()
                time.sleep(0.1)
                self.assertEqual(download, all_bytes(client))
                sender.join(timeout=5)
                self.assertFalse(sender.is_alive())
                self.assertTrue(done.wait(5))
            self.assertEqual([upload], received)
            self.assertFalse(sender_errors)
            self.assert_clean_drain(proxy)

    def test_client_rst_has_exact_socket_side_and_errno_dimensions(self):
        with Origin() as origin, Daemon(origin.address) as proxy:
            with proxy.connect() as client:
                wire = hello()
                client.sendall(wire)
                self.assertEqual(wire, exact(client, len(wire)))
                self.assert_io_dimensions(proxy.snapshot(), 0)
                with proxy.paused():
                    client.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
                    client.close()
            proxy.wait_for(lambda: proxy.snapshot()["active"] == 0)
            counts = proxy.snapshot()
            self.assert_io_dimensions(counts, 1)
            self.assertEqual(1, counts["client_socket_errors"])
            self.assertEqual(1, counts["connection_resets"])
            self.assertEqual(0, counts["last_other_io_errno"])
            self.assertEqual(0, counts["connect_failures"])
            self.assertEqual(0, counts["accept_errors"])

    def test_backend_rst_has_exact_socket_side_and_errno_dimensions(self):
        release = threading.Event()
        reset_done = threading.Event()
        wire = hello()

        def reset_backend(sock):
            self.assertEqual(wire, exact(sock, len(wire)))
            sock.sendall(wire)
            if not release.wait(5):
                raise AssertionError("backend reset was not released")
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
            sock.close()
            reset_done.set()

        with Origin(reset_backend) as origin, Daemon(origin.address) as proxy:
            with proxy.connect() as client:
                try:
                    client.sendall(wire)
                    self.assertEqual(wire, exact(client, len(wire)))
                    self.assert_io_dimensions(proxy.snapshot(), 0)
                    with proxy.paused():
                        release.set()
                        self.assertTrue(reset_done.wait(5))
                    self.assert_closed(client)
                finally:
                    release.set()
            proxy.wait_for(lambda: proxy.snapshot()["active"] == 0)
            counts = proxy.snapshot()
            self.assert_io_dimensions(counts, 1)
            self.assertEqual(1, counts["backend_socket_errors"])
            self.assertEqual(1, counts["connection_resets"])
            self.assertEqual(0, counts["last_other_io_errno"])
            self.assertEqual(0, counts["connect_failures"])
            self.assertEqual(0, counts["accept_errors"])

    def test_deadlines_and_staging_admission_recovery(self):
        with Origin() as origin, Daemon(origin.address, max_connections=4, max_handshakes=2,
                                        hello_timeout_ms=250, idle_timeout_ms=250) as proxy:
            with contextlib.ExitStack() as stack:
                for _ in range(2):
                    sock = stack.enter_context(proxy.connect())
                    sock.sendall(b"\x16")
                proxy.wait_for(lambda: proxy.snapshot()["active"] == 2)
                with proxy.connect() as refused:
                    self.assert_closed(refused)
                time.sleep(0.6)
            counts = proxy.snapshot()
            self.assertGreaterEqual(counts["rejected"], 1)
            self.assertGreaterEqual(counts["timeouts"], 2)
            with proxy.connect() as client:
                wire = hello()
                client.sendall(wire)
                self.assertEqual(wire, exact(client, len(wire)))
                time.sleep(0.6)
                self.assert_closed(client)

    def test_connect_failure_reset_churn_and_fd_reclamation(self):
        with Daemon(f"127.0.0.1:{free_port()}") as proxy:
            with proxy.connect() as client:
                client.sendall(hello())
                self.assert_closed(client)
            counts = proxy.snapshot()
            self.assertEqual(1, counts["connect_failures"])
            self.assert_io_dimensions(counts, 0)
        with Origin() as origin, Daemon(origin.address) as proxy:
            baseline = len(os.listdir(f"/proc/{proxy.process.pid}/fd"))
            for n in range(200):
                with proxy.connect() as client:
                    client.sendall(hello() + b"payload")
                    if n % 3 == 0:
                        client.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
                    else:
                        self.assertEqual(hello() + b"payload", exact(client, len(hello()) + 7))
            proxy.wait_for(lambda: proxy.snapshot()["active"] == 0)
            self.assertEqual(baseline, len(os.listdir(f"/proc/{proxy.process.pid}/fd")))
            self.assert_io_dimensions(proxy.snapshot())

    def test_text_logs_show_compact_activity_and_explicit_totals(self):
        with Origin() as origin, Daemon(origin.address, log_format=None, stats_interval_ms=1000) as proxy:
            wire = hello() + bytes(range(256)) * 8
            with proxy.connect() as client:
                client.sendall(wire)
                client.shutdown(socket.SHUT_WR)
                self.assertEqual(wire, all_bytes(client))
            proxy.wait_for(lambda: "accepted=1" in proxy.logs() and "received=2." in proxy.logs())
            logs = proxy.logs()
            self.assertRegex(logs, r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ INFO  activity; active=0 accepted=1 routed=1 closed=1 sent=2\.\dKiB received=2\.\dKiB")
            self.assertNotIn('{"event"', logs)
            self.assertNotIn("DEBUG", logs)
            self.assertNotIn("io_errors=0", logs)
            old = len(logs)
            proxy.process.send_signal(signal.SIGUSR1)
            proxy.wait_for(lambda: "traffic sent=" in proxy.logs()[old:])
            self.assertIn("totals active=0 accepted=1 routed=1 closed=1", proxy.logs()[old:])
            # Idle timer ticks must not repeat the same totals or status line.
            stable = proxy.logs()
            time.sleep(1.3)
            self.assertEqual(stable, proxy.logs())

    def test_live_warning_batches_and_level_filters(self):
        backend = f"127.0.0.1:{free_port()}"
        for level in ("info", "warn", "error", "none"):
            with self.subTest(level=level), Daemon(backend, log_level=level, log_format="text") as proxy:
                for _ in range(5):
                    with proxy.connect() as client:
                        client.sendall(hello())
                        self.assert_closed(client)
                if level in ("info", "warn"):
                    proxy.wait_for(lambda: "WARN  failures connect_failures=5" in proxy.logs())
                    stable = proxy.logs()
                    time.sleep(1.1)
                    self.assertEqual(stable, proxy.logs())
                    self.assertEqual(1, stable.count("WARN  failures"))
                else:
                    time.sleep(1.3)
                    self.assertEqual("", proxy.logs())
                if level == "warn":
                    self.assertNotIn("INFO", proxy.logs())

    def test_runtime_level_cycle_and_snapshot_while_muted(self):
        with Origin() as origin, Daemon(origin.address, log_level="none") as proxy:
            self.assertEqual("", proxy.logs())
            counts = proxy.snapshot()  # An explicit diagnostic bypasses none.
            self.assertEqual(0, counts["accepted"])
            for level in ("error", "warn", "info", "debug", "none"):
                proxy.process.send_signal(signal.SIGUSR2)
                proxy.wait_for(lambda: any(event.get("event") == "log_level" and
                                          event.get("message") == f"log level changed to {level}"
                                          for event in proxy.events()))
            events = proxy.events()
            self.assertEqual(["error", "warn", "info", "debug", "none"],
                             [event["message"].rsplit(" ", 1)[-1] for event in events if event["event"] == "log_level"])
            muted = proxy.logs()
            with proxy.connect() as client:
                wire = hello()
                client.sendall(wire)
                client.shutdown(socket.SHUT_WR)
                self.assertEqual(wire, all_bytes(client))
            time.sleep(0.3)
            self.assertEqual(muted, proxy.logs())
            self.assertEqual(1, proxy.snapshot()["accepted"])
            proxy.process.send_signal(signal.SIGTERM)
            proxy.process.wait(timeout=5)
            self.assertNotIn('"event":"stopped"', proxy.logs())

    def test_debug_reset_details_do_not_change_accounting_or_log_payload(self):
        with Origin() as origin, Daemon(origin.address, log_level="debug") as proxy:
            wire = hello() + b"PRIVATE-PAYLOAD-MUST-NOT-APPEAR-IN-LOGS"
            with proxy.connect() as client:
                client.sendall(wire)
                self.assertEqual(wire, exact(client, len(wire)))
                with proxy.paused():
                    client.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
                    client.close()
            proxy.wait_for(lambda: any(event.get("event") == "connection_closed" for event in proxy.events()))
            events = proxy.events()
            closed = [event for event in events if event["event"] == "connection_closed"]
            self.assertEqual(1, len(closed))
            self.assertEqual("debug", closed[0]["level"])
            self.assertIn("side=client operation=socket_error errno=104", closed[0]["message"])
            self.assertNotIn("PRIVATE-PAYLOAD", proxy.logs())
            self.assertNotIn('"level":"warn"', proxy.logs())
            counts = proxy.snapshot()
            self.assert_io_dimensions(counts, 1)
            self.assertEqual(1, counts["connection_resets"])

    def test_invalid_log_settings_fail_before_listening(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            base = {"listen": f"127.0.0.1:{free_port()}", "routes": [], "fallback": "127.0.0.1:9443"}
            for key, value in (("log_level", "verbose"), ("log_format", "pretty")):
                with self.subTest(key=key):
                    path.write_text(json.dumps({**base, key: value}), encoding="utf-8")
                    result = subprocess.run([BINARY, str(path)], capture_output=True, timeout=5)
                    self.assertNotEqual(0, result.returncode)
                    self.assertEqual(1, result.stderr.count(b"invalid config"))
                    self.assertNotIn(b"listening on", result.stderr)

    def test_idle_deadline_slides_with_activity_and_can_be_disabled(self):
        with Origin() as origin:
            with Daemon(origin.address, idle_timeout_ms=500) as proxy:
                with proxy.connect() as client:
                    wire = hello()
                    client.sendall(wire)
                    self.assertEqual(wire, exact(client, len(wire)))
                    for _ in range(10):
                        time.sleep(.1)
                        client.sendall(b"active")
                        self.assertEqual(b"active", exact(client, 6))
                    self.assertEqual(0, proxy.snapshot()["timeouts"])
                    time.sleep(.8)
                    self.assert_closed(client)
            with Daemon(origin.address, idle_timeout_ms=0) as proxy:
                with proxy.connect() as client:
                    wire = hello()
                    client.sendall(wire)
                    self.assertEqual(wire, exact(client, len(wire)))
                    time.sleep(.8)
                    client.sendall(b"still alive")
                    self.assertEqual(b"still alive", exact(client, 11))

    def test_fd_pressure_pauses_accept_without_busy_loop(self):
        with Origin() as origin, Daemon(origin.address) as proxy:
            pid = proxy.process.pid
            old = resource.prlimit(pid, resource.RLIMIT_NOFILE)
            with proxy.connect() as established:
                wire = hello()
                established.sendall(wire)
                self.assertEqual(wire, exact(established, len(wire)))
                baseline = len(os.listdir(f"/proc/{pid}/fd"))
                for cycle in range(2):
                    errors_before = proxy.snapshot()["accept_errors"]
                    try:
                        resource.prlimit(pid, resource.RLIMIT_NOFILE, (6, old[1]))
                        with proxy.connect() as pending:
                            time.sleep(0.55)
                            established.sendall(b"alive during pressure")
                            self.assertEqual(b"alive during pressure", exact(established, 21))
                            counts = proxy.snapshot()
                            self.assertGreater(counts["accept_errors"], errors_before)
                            self.assertEqual(1, counts["active"])
                            ticks0 = sum(int(x) for x in Path(f"/proc/{pid}/stat").read_text().split()[13:15])
                            time.sleep(0.55)
                            ticks1 = sum(int(x) for x in Path(f"/proc/{pid}/stat").read_text().split()[13:15])
                            self.assertLess((ticks1 - ticks0) / os.sysconf("SC_CLK_TCK"), 0.2)
                            resource.prlimit(pid, resource.RLIMIT_NOFILE, old)
                            payload = wire + bytes([cycle])
                            pending.sendall(payload)
                            self.assertEqual(payload, exact(pending, len(payload)))
                    finally:
                        resource.prlimit(pid, resource.RLIMIT_NOFILE, old)
                    proxy.wait_for(lambda: proxy.snapshot()["active"] == 1)
                    self.assertEqual(baseline, len(os.listdir(f"/proc/{pid}/fd")))

    def test_v6only_wildcard_routes_to_ipv4_backend_on_same_port(self):
        with Origin() as origin:
            for backend in (origin.address, f"[::ffff:127.0.0.1]:{origin.port}"):
                with Daemon(backend, listen=f"[::]:{origin.port}") as proxy:
                    with socket.create_connection(("::1", origin.port), timeout=5) as client:
                        payload = hello() + b"separate address families"
                        client.sendall(payload)
                        client.shutdown(socket.SHUT_WR)
                        self.assertEqual(payload, all_bytes(client))
                    proxy.wait_for(lambda: proxy.snapshot()["active"] == 0)
                    self.assertEqual(0, proxy.snapshot()["io_errors"])

    def test_hostname_routes_and_fallback_use_startup_resolution(self):
        with Origin() as origin:
            for fallback in (False, True):
                options = {"routes": [], "fallback": f"LoCaLhOsT:{origin.port}"} if fallback else {}
                with Daemon(f"LoCaLhOsT:{origin.port}", **options) as proxy:
                    for _ in range(3):
                        with proxy.connect() as client:
                            payload = hello() + b"hostname backend"
                            client.sendall(payload)
                            client.shutdown(socket.SHUT_WR)
                            self.assertEqual(payload, all_bytes(client))
                    self.assert_clean_drain(proxy)
                    self.assertEqual(1, len(os.listdir(f"/proc/{proxy.process.pid}/task")))

    def test_real_tls_passthrough_and_ipv6_backend(self):
        with tempfile.TemporaryDirectory() as directory:
            cert = str(Path(directory) / "cert.pem")
            key = str(Path(directory) / "key.pem")
            subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                            "-keyout", key, "-out", cert, "-days", "1", "-subj", "/CN=example.com"],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            server_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            server_context.load_cert_chain(cert, key)
            def tls_echo(sock):
                with server_context.wrap_socket(sock, server_side=True) as encrypted:
                    encrypted.sendall(encrypted.recv(1024))
            with Origin(tls_echo, ipv6=True) as origin, Daemon(origin.address) as proxy:
                client_context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
                client_context.check_hostname = False
                client_context.verify_mode = ssl.CERT_NONE
                with client_context.wrap_socket(proxy.connect(), server_hostname="example.com") as client:
                    client.sendall(b"encrypted payload")
                    self.assertEqual(b"encrypted payload", client.recv(1024))

    def test_config_check_and_rejection_before_bind(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            config = {"listen": f"127.0.0.1:{free_port()}", "routes": [],
                      "fallback": "127.0.0.1:9443", "max_connections": 4, "max_handshakes": 2}
            path.write_text(json.dumps(config), encoding="utf-8")
            result = subprocess.run([BINARY, "--check", str(path)], capture_output=True, timeout=5)
            self.assertEqual(0, result.returncode, result.stderr)
            config["unexpected_key"] = True
            path.write_text(json.dumps(config), encoding="utf-8")
            result = subprocess.run([BINARY, str(path)], capture_output=True, timeout=5)
            self.assertNotEqual(0, result.returncode)
            self.assertIn(b"invalid config", result.stderr)
            self.assertNotIn(b"listening on", result.stderr)

    def test_self_routes_and_fallback_rejected_before_bind(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            port = free_port()
            cases = ((f"127.0.0.1:{port}", f"127.0.0.1:{port}"),
                     (f"0.0.0.0:{port}", f"127.0.0.2:{port}"),
                     (f"[::]:{port}", f"[::1]:{port}"),
                     (f"0.0.0.0:{port}", f"[::ffff:127.0.0.1]:{port}"))
            for listen, backend in cases:
                for fallback in (False, True):
                    config = {"listen": listen, "routes": [], "max_connections": 4, "max_handshakes": 2}
                    if fallback:
                        config["fallback"] = backend
                    else:
                        config["routes"] = [{"sni": "example.com", "backend": backend}]
                    path.write_text(json.dumps(config), encoding="utf-8")
                    for flags in ([], ["--check"]):
                        with self.subTest(listen=listen, backend=backend, fallback=fallback, flags=flags):
                            result = subprocess.run([BINARY, *flags, str(path)], capture_output=True, timeout=5)
                            self.assertNotEqual(0, result.returncode)
                            self.assertIn(b"BackendEqualsListener", result.stderr)
                            self.assertNotIn(b"listening on", result.stderr)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--binary", default=BINARY)
    args, rest = parser.parse_known_args()
    BINARY = str(Path(args.binary).resolve())
    unittest.main(argv=[__file__, *rest], verbosity=2)
