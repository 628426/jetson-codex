#!/usr/bin/env python3
"""Portable checks for the rclone pre-build health gate (no real OAuth needed)."""
import os
from pathlib import Path
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[1]

def executable(path: Path, source: str) -> None:
    path.write_text("#!/bin/sh\n" + source)
    path.chmod(0o755)

def run_gate(env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", "./storage-health.sh"],
        cwd=REPO, env=env, capture_output=True, text=True, timeout=15
    )

with tempfile.TemporaryDirectory(prefix="storage-gate-") as tmp:
    home = Path(tmp)
    bin_dir = home / "mock-bin"
    bin_dir.mkdir()
    mount = home / "jetson-codex-cloud"
    mount.mkdir()
    config_dir = home / ".config/jetson-codex"
    config_dir.mkdir(parents=True)
    env_file = config_dir / "storage.env"
    env_file.write_text(
        "RCLONE_REMOTE=cloud\n"
        "RCLONE_SOURCE=cloud:Codex\n"
        f"RCLONE_MOUNT={mount}\n"
        f"RCLONE_CACHE={home / 'cache'}\n"
    )
    executable(
        bin_dir / "rclone",
        'if [ "${MOCK_REMOTE_DOWN:-0}" = "1" ]; then exit 19; fi\n'
        'exit 0\n'
    )
    executable(
        bin_dir / "systemctl",
        'if [ "${MOCK_SERVICE_DOWN:-0}" = "1" ]; then exit 19; fi\n'
        'exit 0\n'
    )
    executable(
        bin_dir / "mountpoint",
        'if [ "${MOCK_MOUNT_DOWN:-0}" = "1" ]; then exit 19; fi\n'
        'exit 0\n'
    )
    executable(
        bin_dir / "sudo",
        'if [ "${MOCK_DOCKER_ROOT_DENIED:-0}" = "1" ]; then exit 13; fi\n'
        'exit 0\n'
    )
    env = dict(os.environ, HOME=str(home), USER="dex",
               XDG_CONFIG_HOME=str(home / ".config"),
               PATH=f"{bin_dir}:{os.environ['PATH']}")

    # Valid OAuth plus working service, FUSE mount and file read.
    ok = run_gate(env)
    assert ok.returncode == 0, (ok.stdout, ok.stderr)
    assert "PASS: remote OAuth/access" in ok.stdout

    # Remote unavailable: do not continue to a Docker build.
    down = run_gate(dict(env, MOCK_REMOTE_DOWN="1"))
    assert down.returncode != 0
    assert "Remote listing failed" in down.stdout
    assert "PAUSED before Docker build" in down.stdout
    assert "Windows PowerShell" in down.stderr

    # Service running but no actual FUSE mount: this is also a hard stop.
    absent = run_gate(dict(env, MOCK_MOUNT_DOWN="1"))
    assert absent.returncode != 0
    assert "Cloud folder is not actually mounted" in absent.stdout

    # FUSE can work for dex but not Docker's root daemon: block startup.
    root_denied = run_gate(dict(env, MOCK_DOCKER_ROOT_DENIED="1"))
    assert root_denied.returncode != 0
    assert "Docker's root user cannot read" in root_denied.stdout
    assert "PAUSED before Docker build" in root_denied.stdout

    # Broken saved configuration must be recoverable, not silently ignored.
    env_file.write_text("RCLONE_REMOTE=cloud\n")
    malformed = run_gate(env)
    assert malformed.returncode != 0
    assert "incomplete" in malformed.stdout.lower()

print("PASS: rclone remote, mount, service and malformed-config gates")
