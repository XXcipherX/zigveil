#!/usr/bin/env python3
"""Install, update and reject a bad preflight on a disposable Linux systemd host."""
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

ROOT = Path(__file__).resolve().parent.parent


def command(*args, check=True, env=None):
    result = subprocess.run(args, capture_output=True, text=True, timeout=180, env=env)
    if check and result.returncode:
        raise AssertionError(result.stdout + result.stderr)
    return result


def verify_stream(port):
    with socket.create_connection(("127.0.0.1", port), timeout=5) as client:
        client.settimeout(5)
        payload = hello(fragment=2) + os.urandom(128 * 1024)
        client.sendall(payload)
        client.shutdown(socket.SHUT_WR)
        assert all_bytes(client) == payload


def run(image):
    assert os.geteuid() == 0, "Run on a disposable host as root"
    unit = Path("/etc/systemd/system/zigveil.service")
    assert not unit.exists(), "The test requires a host without Zigveil installed"
    assert command("docker", "inspect", "zigveil", check=False).returncode != 0, "A Zigveil container already exists"
    registry = "zigveil-registry-" + uuid.uuid4().hex[:12]
    registry_port = free_port()
    registry_image = f"127.0.0.1:{registry_port}/zigveil:e2e"
    command("docker", "run", "-d", "--name", registry, "-p", f"127.0.0.1:{registry_port}:5000", "registry:3")
    try:
        command("docker", "tag", image, registry_image)
        for attempt in range(30):
            pushed = command("docker", "push", registry_image, check=False)
            if pushed.returncode == 0:
                break
            time.sleep(.2)
        else:
            raise AssertionError(pushed.stdout + pushed.stderr)
        with tempfile.TemporaryDirectory(prefix="zigveil-installer-") as directory, Origin() as origin:
            install_dir = Path(directory) / "install"
            port = free_port()
            env = dict(os.environ, INSTALL_DIR=str(install_dir), REPO_RAW_URL=ROOT.as_uri(),
                       IMAGE=registry_image, INSTALL_DOCKER="false", LISTEN=f"127.0.0.1:{port}",
                       SNI="example.com", BACKEND=origin.address)
            try:
                result = command("bash", str(ROOT / "deploy/install_docker_compose.sh"), env=env)
                print(result.stdout)
                config = install_dir / "config.json"
                original = config.read_bytes()
                assert config.stat().st_mode & 0o777 == 0o600
                assert config.stat().st_uid == 0
                assert json.loads(original)["routes"][0]["backend"] == origin.address
                command("systemctl", "is-enabled", "--quiet", "zigveil.service")
                command("systemctl", "is-active", "--quiet", "zigveil.service")
                verify_stream(port)
                # An operator may mute logs before an update. Readiness and the
                # explicit --check preflight must not depend on INFO messages.
                muted = json.loads(original)
                muted["log_level"] = "none"
                config.write_text(json.dumps(muted), encoding="utf-8")
                original = config.read_bytes()
                environment = (install_dir / ".env").read_bytes()
                pid = command("docker", "inspect", "-f", "{{.State.Pid}}", "zigveil").stdout.strip()
                # Enough for the container runtime, below Zigveil's 2060-fd minimum.
                bad_env = dict(env, NOFILE_LIMIT="1024")
                bad = command("bash", str(ROOT / "deploy/install_docker_compose.sh"), env=bad_env, check=False)
                assert bad.returncode and "RaiseRLIMIT_NOFILE" in bad.stdout + bad.stderr, bad.stdout + bad.stderr
                assert config.read_bytes() == original
                assert (install_dir / ".env").read_bytes() == environment
                assert command("docker", "inspect", "-f", "{{.State.Pid}}", "zigveil").stdout.strip() == pid
                verify_stream(port)
                update_env = dict(env, SNI="example.org", BACKEND="127.0.0.1:1")
                result = command("bash", str(ROOT / "deploy/install_docker_compose.sh"), env=update_env)
                print(result.stdout)
                assert config.read_bytes() == original
                assert command("docker", "inspect", "-f", "{{.State.Pid}}", "zigveil").stdout.strip() != pid
                verify_stream(port)
                logs = command("docker", "logs", "zigveil")
                assert logs.stdout + logs.stderr == "", logs
            finally:
                print(command("journalctl", "-u", "zigveil.service", "--no-pager", "-n", "80", check=False).stdout)
                command("systemctl", "disable", "--now", "zigveil.service", check=False)
                command("docker", "rm", "-f", "zigveil", check=False)
                if unit.exists():
                    unit.unlink()
                command("systemctl", "daemon-reload")
                command("systemctl", "reset-failed", "zigveil.service", check=False)
    finally:
        command("docker", "rm", "-f", registry, check=False)
    print("Installer E2E passed: install, stream, failed preflight, preserved config and update")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", required=True)
    run(parser.parse_args().image)
