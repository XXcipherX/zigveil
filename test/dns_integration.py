#!/usr/bin/env python3
"""Controlled Linux DNS tests in a private mount namespace (requires root)."""
import argparse
import contextlib
import ipaddress
import json
import os
import socket
import struct
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path

import integration
from integration import Daemon, Origin, all_bytes, free_port, hello


class NameServer:
    def __init__(self):
        self.socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.address = f"127.200.{os.getpid() % 250}.{os.getpid() // 250 % 250 + 1}"
        self.socket.bind((self.address, 53))
        self.socket.settimeout(0.1)
        self.records = {}
        self.requests = []
        self.errors = []
        self.stopped = threading.Event()
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def serve(self):
        while not self.stopped.is_set():
            try:
                packet, peer = self.socket.recvfrom(4096)
            except socket.timeout:
                continue
            except OSError:
                return
            try:
                index, labels = 12, []
                while packet[index]:
                    size = packet[index]
                    labels.append(packet[index + 1:index + 1 + size].decode("ascii"))
                    index += size + 1
                index += 1
                kind, query_class = struct.unpack("!HH", packet[index:index + 4])
                if query_class != 1 or kind not in (1, 28):
                    raise AssertionError("unexpected DNS query")
                name = ".".join(labels).lower()
                self.requests.append((name, kind))
                addresses = self.records.get(name)
                answers = []
                for text in addresses or ():
                    addr = ipaddress.ip_address(text)
                    if (kind == 1) != (addr.version == 4):
                        continue
                    answers.append(b"\xc0\x0c" + struct.pack("!HHIH", kind, 1, 60, len(addr.packed)) + addr.packed)
                flags = 0x8183 if addresses is None else 0x8180
                header = packet[:2] + struct.pack("!HHHHH", flags, 1, len(answers), 0, 0)
                self.socket.sendto(header + packet[12:index + 4] + b"".join(answers), peer)
            except Exception as exc:
                self.errors.append(exc)

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.stopped.set()
        self.socket.close()
        self.thread.join(timeout=2)
        if self.thread.is_alive() or self.errors:
            raise AssertionError(self.errors or "DNS fixture failed to stop")


@contextlib.contextmanager
def namespace(server, hosts_text="", options="timeout:1 attempts:1", search=""):
    with tempfile.TemporaryDirectory() as directory:
        hosts = Path(directory) / "hosts"
        resolv = Path(directory) / "resolv.conf"
        hosts.write_text(hosts_text, encoding="ascii")
        resolv.write_text(f"nameserver {server.address}\noptions {options}\n"
                          + (f"search {search}\n" if search else ""), encoding="ascii")
        # Only this child's mount namespace sees these files; the host is unchanged.
        script = 'mount --bind "$1" /etc/hosts; mount --bind "$2" /etc/resolv.conf; shift 2; exec "$@"'
        yield ["unshare", "--mount", "--propagation", "private", "sh", "-eu", "-c", script,
               "zigveil-dns", str(hosts), str(resolv)]


class DnsIntegration(unittest.TestCase):
    def transfer(self, proxy):
        with proxy.connect() as client:
            wire = hello() + bytes(range(256)) * 32
            client.sendall(wire)
            client.shutdown(socket.SHUT_WR)
            self.assertEqual(wire, all_bytes(client))
        proxy.wait_for(lambda: proxy.snapshot()["active"] == 0)
        self.assertEqual(0, proxy.snapshot()["io_errors"])
        self.assertEqual(1, len(os.listdir(f"/proc/{proxy.process.pid}/task")))

    def test_dns_many_answers_prefers_ipv4_and_does_not_refresh_during_relay(self):
        with NameServer() as dns, namespace(dns) as prefix, Origin() as origin:
            name = "backend.example.test"
            dns.records[name] = ["127.0.0.1"] + [f"203.0.113.{n}" for n in range(1, 21)] + ["::1"]
            with Daemon(f"BaCkEnD.ExAmPlE.TeSt:{origin.port}", launch_prefix=prefix) as proxy:
                self.transfer(proxy)
                self.assertEqual({(name, 1), (name, 28)}, set(dns.requests))
                before = list(dns.requests)
                dns.records[name] = ["127.0.0.2"]
                self.transfer(proxy)
                self.transfer(proxy)
                self.assertEqual(before, dns.requests)

    def test_dns_ipv6_only_fallback(self):
        with NameServer() as dns, namespace(dns) as prefix, Origin(ipv6=True) as origin:
            name = "fallback.example.test"
            dns.records[name] = ["::1"]
            with Daemon(origin.address, launch_prefix=prefix, routes=[], fallback=f"{name}.:{origin.port}") as proxy:
                self.transfer(proxy)
                self.assertEqual({(name, 1), (name, 28)}, set(dns.requests))

    def test_overlong_search_candidate_is_skipped_before_bare_lookup(self):
        name = ".".join(("a" * 63, "b" * 63, "c" * 63, "d" * 30))
        with NameServer() as dns, namespace(dns, options="timeout:1 attempts:1 ndots:5", search="e" * 40) as prefix, Origin() as origin:
            dns.records[name] = ["127.0.0.1"]
            with Daemon(f"{name}:{origin.port}", launch_prefix=prefix) as proxy:
                self.transfer(proxy)
            self.assertEqual({(name, 1), (name, 28)}, set(dns.requests))

    def test_valid_search_then_absolute_name_and_hosts_bypass(self):
        with NameServer() as dns, Origin() as origin:
            dns.records["backend.example.test"] = ["127.0.0.1"]
            for endpoint, hosts in (("backend", ""), ("backend.example.test.", ""),
                                    ("backend", "127.0.0.1 BACKEND\n")):
                dns.requests.clear()
                with namespace(dns, hosts, search="bad..suffix example.test") as prefix:
                    with Daemon(f"{endpoint}:{origin.port}", launch_prefix=prefix) as proxy:
                        self.transfer(proxy)
                self.assertEqual(set() if hosts else {("backend.example.test", 1), ("backend.example.test", 28)}, set(dns.requests))

    def test_large_hosts_answer_list_is_drained_without_dns_or_worker_leaks(self):
        with NameServer() as dns, Origin() as origin:
            hosts = "127.0.0.1 backend.example.test\n" * 100
            with namespace(dns, hosts) as prefix, Daemon(f"backend.example.test:{origin.port}", launch_prefix=prefix) as proxy:
                self.transfer(proxy)
                self.assertFalse(dns.requests)

    def test_dns_failures_and_resolved_self_targets_rejected_before_bind(self):
        with NameServer() as dns, namespace(dns) as prefix, tempfile.TemporaryDirectory() as directory:
            dns.records["self.example.test"] = ["127.0.0.1"]
            for host in ("missing.example.test", "self.example.test"):
                for fallback in (False, True):
                    port = free_port()
                    config = {"listen": f"0.0.0.0:{port}", "routes": [], "max_connections": 4, "max_handshakes": 2}
                    if fallback:
                        config["fallback"] = f"{host}:{port}"
                    else:
                        config["routes"] = [{"sni": "example.com", "backend": f"{host}:{port}"}]
                    path = Path(directory) / "config.json"
                    path.write_text(json.dumps(config), encoding="utf-8")
                    for flags in ([], ["--check"]):
                        with self.subTest(host=host, fallback=fallback, flags=flags):
                            result = subprocess.run([*prefix, integration.BINARY, *flags, str(path)],
                                                    capture_output=True, timeout=5)
                            self.assertNotEqual(0, result.returncode)
                            self.assertIn(b"invalid config", result.stderr)
                            if host.startswith("self."):
                                self.assertIn(b"BackendEqualsListener", result.stderr)
                            else:
                                self.assertIn(b"NoAddressReturned", result.stderr)
                            self.assertNotIn(b"listening on", result.stderr)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--binary", default=integration.BINARY)
    args, rest = parser.parse_known_args()
    if os.geteuid() != 0:
        parser.error("controlled DNS tests require a disposable root-capable Linux environment")
    integration.BINARY = str(Path(args.binary).resolve())
    unittest.main(argv=[__file__, *rest], verbosity=2)
