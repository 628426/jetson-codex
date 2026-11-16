#!/usr/bin/env python3
"""Mock APT package reconciliation for Orin CDI hook crash (no real packages changed)."""
import os
from pathlib import Path
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[1]
FAKE_DPKG_QUERY = """#!/bin/sh
if [ -f "$MOCK_UPDATED" ]; then
  printf '%s' "$MOCK_CANDIDATE"
else
  printf '%s' "$MOCK_INSTALLED"
fi
"""
FAKE_APT_CACHE = """#!/bin/sh
case "$2" in
  libnvidia-container1)
    printf '  Candidate: %s\\n' "${MOCK_FOURTH_CANDIDATE:-$MOCK_CANDIDATE}" ;;
  *)
    printf '  Candidate: %s\\n' "$MOCK_CANDIDATE" ;;
esac
"""
FAKE_APT_GET = """#!/bin/sh
printf 'apt-get %s\\n' "$*" >> "$MOCK_LOG"
if [ "$1" = -s ]; then
  if [ "$MOCK_REMOVAL" = yes ]; then
    printf 'Remv docker-ce [1.0]\\n'
  else
    printf 'Inst nvidia-container-toolkit [1.19.0] (1.19.1)\\n'
  fi
fi
exit 0
"""
FAKE_SUDO = """#!/bin/sh
printf 'sudo %s\\n' "$*" >> "$MOCK_LOG"
if [ "$1" = apt-get ] && [ "$2" = install ]; then
  : > "$MOCK_UPDATED"
fi
exit 0
"""

def executable(path, content):
    path.write_text(content)
    path.chmod(0o755)

def check(installed, candidate, fourth=None, removal="no"):
    with tempfile.TemporaryDirectory(prefix="jetson-cdi-test-") as tmp:
        root = Path(tmp)
        b = root / "bin"
        b.mkdir()
        for binary, script in [
            ("dpkg-query", FAKE_DPKG_QUERY),
            ("apt-cache", FAKE_APT_CACHE),
            ("apt-get", FAKE_APT_GET),
            ("sudo", FAKE_SUDO),
        ]:
            executable(b / binary, script)
        log = root / "apt.log"
        log.touch()
        updated = root / "updated"
        env = dict(
            os.environ,
            PATH=f"{b}:{os.environ['PATH']}",
            MOCK_INSTALLED=installed, MOCK_CANDIDATE=candidate,
            MOCK_FOURTH_CANDIDATE=fourth or candidate,
            MOCK_REMOVAL=removal,
            MOCK_UPDATED=str(updated), MOCK_LOG=str(log),
        )
        result = subprocess.run(["bash", "./check-nvidia-toolkit.sh"], cwd=REPO,
                                env=env, stdin=subprocess.DEVNULL,
                                capture_output=True, text=True, timeout=15)
        return result, log.read_text(), updated.exists()

ready, log, installed = check("1.19.1-1", "1.19.1-1")
assert ready.returncode == 0, (ready.stdout, ready.stderr)
assert "no changes" in ready.stdout.lower()
assert not installed and not log

fixed, log, installed = check("1.19.0-1", "1.19.1-1")
assert fixed.returncode == 0, (fixed.stdout, fixed.stderr)
assert installed
assert "sudo apt-get update" in log
assert "nvidia-container-toolkit=1.19.1-1" in log
assert "nvidia-container-toolkit-base=1.19.1-1" in log
assert "libnvidia-container-tools=1.19.1-1" in log
assert "libnvidia-container1=1.19.1-1" in log

stale, log, installed = check("1.19.0-1", "1.19.0-1")
assert stale.returncode != 0
assert not installed and "sudo apt-get install" not in log
assert "below NVIDIA's fixed" in stale.stderr

mixed, log, installed = check("1.19.0-1", "1.19.1-1",
                              fourth="1.20.1-1")
assert mixed.returncode != 0
assert not installed and "sudo apt-get install" not in log
assert "Mixed NVIDIA toolkit candidates" in mixed.stderr

removes, log, installed = check("1.19.0-1", "1.19.1-1", removal="yes")
assert removes.returncode != 0
assert not installed and "sudo apt-get install" not in log
assert "Refusing NVIDIA toolkit update" in removes.stderr

print("PASS: modern toolkit no-op, fixed family install, stale/mixed/removal safe failure")
