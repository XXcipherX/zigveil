#!/usr/bin/env python3
"""Exercise the image entrypoint, read-only configuration and real TCP forwarding."""
import argparse
import json
import os
import socket
import subprocess
import tempfile
import time
import uuid
from pathlib import Path

from integration import Origin, all_bytes, exact, free_port, hello


def command(*args, check=True):
    result = subprocess.run(args, capture_output=True, text=True, timeout=60)
    if check and result.returncode:
        raise AssertionError(result.stdout + result.stderr)
    return result


def check_embedded_dns(image, common, config, directory, mount):
    # A running endpoint registers backend.test with Docker's DNS, not /etc/hosts.
    network = "zigveil-dns-" + uuid.uuid4().hex[:12]
    name = network + "-endpoint"
    command("docker", "network", "create", network)
    try:
        command(*common, "-d", "--name", name, "--network", network,
                "--network-alias", "backend.test", "--mount", mount, image)
        assert command("docker", "inspect", "-f", "{{.State.Running}}", name).stdout.strip() == "true"
        dns_config = dict(config)
        dns_config["routes"] = [{"sni": "example.com", "backend": "backend.test:443"}]
        dns_path = Path(directory) / "dns.json"
        dns_path.write_text(json.dumps(dns_config), encoding="utf-8")
        dns_mount = f"type=bind,source={dns_path},target=/etc/zigveil/dns.json,readonly"
        checked = command(*common, "--network", network, "--mount", dns_mount, image,
                          "--check", "/etc/zigveil/dns.json")
        assert "config valid" in checked.stderr, checked
    finally:
        command("docker", "rm", "-f", name, check=False)
        command("docker", "network", "rm", network, check=False)


def smoke(image):
    common = ["docker", "run", "--rm", "--read-only", "--cap-drop", "ALL",
              "--cap-add", "NET_BIND_SERVICE", "--security-opt", "no-new-privileges:true",
              "--ulimit", "nofile=65536:65536"]
    metadata = json.loads(command("docker", "image", "inspect", image).stdout)[0]
    assert metadata["Config"]["Entrypoint"] == ["/usr/local/bin/zigveil"], metadata["Config"]
    assert metadata["Config"]["Cmd"] == ["/etc/zigveil/config.json"], metadata["Config"]
    print(f"Runtime image size: {metadata['Size']} bytes")
    version = command(*common, image, "--version").stderr
    assert "zigveil 0.1.0 (Zig 0.17.0," in version, version
    assert "Usage: zigveil CONFIG.json" in command(*common, image, "--help").stderr
    missing = command(*common, image, check=False)
    assert missing.returncode and "cannot read config /etc/zigveil/config.json: OpenFailed" in missing.stderr, missing
    with tempfile.TemporaryDirectory() as directory, Origin() as origin:
        port = free_port()
        path = Path(directory) / "config.json"
        config = {"listen": f"127.0.0.1:{port}", "routes": [{"sni": "example.com", "backend": origin.address}],
                  "max_connections": 4, "max_handshakes": 2, "stats_interval_ms": 0}
        path.write_text(json.dumps(config), encoding="utf-8")
        mount = f"type=bind,source={path},target=/etc/zigveil/config.json,readonly"
        checked = command(*common, "--mount", mount, image, "--check", "/etc/zigveil/config.json")
        assert "config valid" in checked.stderr, checked
        check_embedded_dns(image, common, config, directory, mount)
        config["unexpected_key"] = True
        path.write_text(json.dumps(config), encoding="utf-8")
        invalid = command(*common, "--mount", mount, image, "--check", "/etc/zigveil/config.json", check=False)
        assert invalid.returncode and "invalid config" in invalid.stderr, invalid
        invalid = command(*common, "--mount", mount, image, check=False)
        assert invalid.returncode and "invalid config" in invalid.stderr, invalid
        config.pop("unexpected_key")
        config["routes"][0]["backend"] = f"backend.test:{origin.port}"
        path.write_text(json.dumps(config), encoding="utf-8")
        before = path.read_bytes()
        name = "zigveil-smoke-" + uuid.uuid4().hex[:12]
        command("docker", "run", "-d", "--name", name, "--network", "host", "--read-only",
                "--add-host", "backend.test:127.0.0.1",
                "--cap-drop", "ALL", "--cap-add", "NET_BIND_SERVICE", "--security-opt", "no-new-privileges:true",
                "--ulimit", "nofile=65536:65536", "--mount", mount, image)
        try:
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                logs = command("docker", "logs", name)
                if "listening on" in logs.stdout + logs.stderr:
                    break
                time.sleep(.1)
            else:
                raise AssertionError(logs.stdout + logs.stderr)
            with socket.create_connection(("127.0.0.1", port), timeout=5) as client:
                client.settimeout(5)
                payload = hello("ExAmPle.COM", padding=24000) + os.urandom(256 * 1024)
                client.sendall(payload)
                client.shutdown(socket.SHUT_WR)
                assert all_bytes(client) == payload
            with socket.create_connection(("127.0.0.1", port), timeout=5) as client:
                client.settimeout(5)
                payload = hello() + os.urandom(256 * 1024)
                client.sendall(payload)
                assert exact(client, len(payload)) == payload
                started = time.monotonic()
                result = subprocess.run(["docker", "stop", "--timeout", "35", name],
                                        capture_output=True, text=True, timeout=10)
                assert result.returncode == 0, result.stdout + result.stderr
                assert time.monotonic() - started < 10
                try:
                    assert client.recv(1) == b"", "client socket remained open"
                except ConnectionResetError:
                    pass
            assert command("docker", "inspect", "-f", "{{.State.ExitCode}}", name).stdout.strip() == "0"
            command("docker", "start", name)
            deadline = time.monotonic() + 15
            while True:
                try:
                    with socket.create_connection(("127.0.0.1", port), timeout=1) as client:
                        client.settimeout(5)
                        wire = hello()
                        client.sendall(wire)
                        assert exact(client, len(wire)) == wire
                    break
                except (ConnectionRefusedError, socket.timeout):
                    if time.monotonic() >= deadline:
                        raise AssertionError("restarted container failed to listen")
                    time.sleep(.1)
            command("docker", "stop", "--timeout", "35", name)
            assert command("docker", "inspect", "-f", "{{.State.ExitCode}}", name).stdout.strip() == "0"
            assert path.read_bytes() == before
        finally:
            logs = command("docker", "logs", name, check=False)
            print(logs.stdout + logs.stderr)
            command("docker", "rm", "-f", name, check=False)
    print("Docker smoke passed: direct CLI, config validation, hosts/DNS, prefix, bulk, FIN and shutdown")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", required=True)
    smoke(parser.parse_args().image)
