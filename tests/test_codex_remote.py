#!/usr/bin/env python3
"""Mock CLI checks: native pairing stays inside Docker and is not reissued on non-TTY reruns."""
import os
from pathlib import Path
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[1]
MOCK_DOCKER = """#!/bin/sh
printf '%s\\n' "$*" >> "$MOCK_DOCKER_LOG"
if [ "$1" = ps ]; then printf 'jetson-codex\\n'; exit 0; fi
if [ "$1" = exec ]; then
  case "$*" in
    *'codex login status'*)
      [ "${MOCK_AUTH:-1}" = 1 ]; exit $? ;;
    *'codex remote-control --help'*)
      [ "${MOCK_FEATURE:-1}" = 1 ]; exit $? ;;
    *'codex remote-control start --json'*)
      [ "${MOCK_START:-1}" = 1 ]; exit $? ;;
  esac
fi
exit 0
"""

def check(mode: str, overrides=None):
    with tempfile.TemporaryDirectory(prefix="remote-mock-") as tmp:
        root = Path(tmp)
        bins = root / "bin"
        bins.mkdir()
        fake_docker = bins / "docker"
        fake_docker.write_text(MOCK_DOCKER)
        fake_docker.chmod(0o755)
        log = root / "calls"
        log.touch()
        env = dict(os.environ,
                   PATH=f"{bins}:{os.environ['PATH']}",
                   MOCK_DOCKER_LOG=str(log))
        env.update(overrides or {})
        result = subprocess.run(
            ["bash", "./codex-remote.sh", mode], cwd=REPO, env=env,
            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=10
        )
        return result, log.read_text()

started, log = check("start")
assert started.returncode == 0, (started.stdout, started.stderr)
assert "codex remote-control start --json" in log
assert "codex remote-control pair" not in log
assert "docker rm" not in log

auto, log = check("auto")
assert auto.returncode == 0, (auto.stdout, auto.stderr)
assert "No interactive terminal" in auto.stdout
assert "codex remote-control pair" not in log

unauth, log = check("auto", {"MOCK_AUTH": "0"})
assert unauth.returncode == 0
assert "not authenticated" in unauth.stdout
assert "codex remote-control start" not in log

failed, log = check("start", {"MOCK_START": "0"})
assert failed.returncode != 0
assert "failed to start" in failed.stdout
assert "codex remote-control pair" not in log

unsupported, log = check("auto", {"MOCK_FEATURE": "0"})
assert unsupported.returncode != 0
assert "does not support" in unsupported.stderr
assert "codex remote-control pair" not in log

no_tty, log = check("pair")
assert no_tty.returncode != 0
assert "interactive terminal" in no_tty.stderr
assert "codex remote-control pair" not in log

# The container's existing entrypoint restores remote control on reboot.
MOCK_CODEX = """#!/bin/sh
printf '%s\\n' "$*" >> "$MOCK_CODEX_LOG"
[ "${MOCK_CODEX_AUTH:-1}" = 1 ] || exit 1
"""
with tempfile.TemporaryDirectory(prefix="remote-restart-") as tmp:
    root = Path(tmp)
    bins = root / "bin"
    bins.mkdir()
    codex = bins / "codex"
    codex.write_text(MOCK_CODEX)
    codex.chmod(0o755)
    fake_sleep = bins / "sleep"
    fake_sleep.write_text("#!/bin/sh\nexit 0\n")
    fake_sleep.chmod(0o755)
    calls = root / "codex-calls"
    calls.touch()
    env = dict(os.environ,
               MOCK_CODEX_LOG=str(calls),
               PATH=f"{bins}:{os.environ['PATH']}")
    restarted = subprocess.run(["bash", "./container-keepalive.sh"],
                               cwd=REPO, env=env, capture_output=True,
                               text=True, timeout=10)
    assert restarted.returncode == 0, (restarted.stdout, restarted.stderr)
    assert "remote-control start --json" in calls.read_text()
    assert "login status" in calls.read_text()

print("PASS: authenticated remote startup, non-TTY safety, failure handling and reboot restore")
