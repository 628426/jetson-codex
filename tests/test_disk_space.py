#!/usr/bin/env python3
"""Mock Docker and df to test aggressive disk cleanup without a Docker daemon."""
import os
from pathlib import Path
import subprocess
import tempfile
import time

REPO = Path(__file__).resolve().parents[1]

def executable(path: Path, content: str) -> None:
    path.write_text("#!/bin/sh\n" + content)
    path.chmod(0o755)

def invoke(env: dict[str, str], *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", "./disk-space.sh", *args],
        cwd=REPO, env=env, capture_output=True, text=True, timeout=12
    )

with tempfile.TemporaryDirectory(prefix="jetson-disk-test-") as tmp:
    root = Path(tmp)
    bins = root / "bin"
    bins.mkdir()
    docker_root = root / "docker"
    docker_root.mkdir()
    docker_log = root / "docker.log"
    docker_log.touch()
    executable(bins / "docker", """printf '%s\\n' "$*" >> "$MOCK_DOCKER_LOG"
if [ "$1" = "info" ]; then printf '%s\\n' "$MOCK_DOCKER_ROOT"; fi
exit 0
""")
    executable(bins / "df", """printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\\n'
printf '/dev/mock 99999999 1 %s 1%% /docker\\n' "$MOCK_AVAILABLE_KIB"
""")
    executable(bins / "sleep", "exec /bin/sleep 0.03\n")
    env = dict(os.environ,
               PATH=f"{bins}:{os.environ['PATH']}",
               MOCK_DOCKER_ROOT=str(docker_root),
               MOCK_DOCKER_LOG=str(docker_log),
               MOCK_AVAILABLE_KIB=str(24 * 1024 * 1024))

    pre = invoke(env, "pre")
    assert pre.returncode == 0, (pre.stdout, pre.stderr)
    log = docker_log.read_text()
    assert "buildx prune --all --force --filter inuse=false" in log
    assert "image prune --force" in log
    assert "volume" not in log and "system prune" not in log

    # A monitor with plentiful free disk space should not prune.
    docker_log.write_text("")
    watcher = subprocess.Popen(["bash", "./disk-space.sh", "monitor", str(os.getpid())],
                               cwd=REPO, env=env, stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL)
    time.sleep(0.14)
    watcher.terminate()
    watcher.wait(timeout=3)
    assert "buildx prune" not in docker_log.read_text()

    # At <12 GiB, monitor prunes all eligible cache, not a cache quota.
    docker_log.write_text("")
    low = dict(env, MOCK_AVAILABLE_KIB=str(4 * 1024 * 1024))
    watcher = subprocess.Popen(["bash", "./disk-space.sh", "monitor", str(os.getpid())],
                               cwd=REPO, env=low, stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL)
    deadline = time.monotonic() + 3
    while "buildx prune" not in docker_log.read_text() and time.monotonic() < deadline:
        time.sleep(0.04)
    watcher.terminate()
    watcher.wait(timeout=3)
    assert "buildx prune --all --force --filter inuse=false" in docker_log.read_text()

    docker_log.write_text("")
    post = invoke(env, "post")
    assert post.returncode == 0, (post.stdout, post.stderr)
    log = docker_log.read_text()
    assert "buildx prune --all --force --filter inuse=false" in log
    assert "image prune --force" in log
    assert "system df" in log
    assert "volume" not in log and "system prune" not in log

print("PASS: pre/during/post Docker reclamation; active images and volumes preserved")
