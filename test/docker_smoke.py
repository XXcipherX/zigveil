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

from integration import Origin, all_bytes, free_port, hello


def command(*args, check=True):
    result = subprocess.run(args, capture_output=True, text=True, timeout=60)
    if check and result.returncode:
        raise AssertionError(result.stdout + result.stderr)
    return result


def smoke(image):
    common = ["docker", "run", "--rm", "--read-only", "--cap-drop", "ALL",
              "--cap-add", "NET_BIND_SERVICE", "--security-opt", "no-new-privileges:true",
              "--ulimit", "nofile=65536:65536"]
    version = command(*common, image, "--version").stderr
    assert "zigveil 0.1.0 (Zig 0.17.0," in version, version
    missing = command(*common, image, check=False)
    assert missing.returncode and "mount a readable config.json" in missing.stderr, missing
    with tempfile.TemporaryDirectory() as directory, Origin() as origin:
        port = free_port()
        path = Path(directory) / "config.json"
        config = {"listen": f"127.0.0.1:{port}", "routes": [{"sni": "example.com", "backend": origin.address}],
                  "max_connections": 4, "max_handshakes": 2, "stats_interval_ms": 0}
        path.write_text(json.dumps(config), encoding="utf-8")
        before = path.read_bytes()
        mount = f"type=bind,source={path},target=/etc/zigveil/config.json,readonly"
        command(*common, "--mount", mount, image, "--check", "/etc/zigveil/config.json")
        config["unexpected_key"] = True
        path.write_text(json.dumps(config), encoding="utf-8")
        invalid = command(*common, "--mount", mount, image, "--check", "/etc/zigveil/config.json", check=False)
        assert invalid.returncode and "invalid config" in invalid.stderr, invalid
        path.write_bytes(before)
        name = "zigveil-smoke-" + uuid.uuid4().hex[:12]
        command("docker", "run", "-d", "--name", name, "--network", "host", "--read-only",
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
            command("docker", "stop", "--timeout", "35", name)
            assert command("docker", "inspect", "-f", "{{.State.ExitCode}}", name).stdout.strip() == "0"
            assert path.read_bytes() == before
        finally:
            logs = command("docker", "logs", name, check=False)
            print(logs.stdout + logs.stderr)
            command("docker", "rm", "-f", name, check=False)
    print("Docker smoke passed: entrypoint, config validation, prefix, bulk, FIN and shutdown")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", required=True)
    smoke(parser.parse_args().image)
