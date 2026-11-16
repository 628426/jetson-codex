#!/usr/bin/env python3
"""Mock Docker to ensure repeat runs preserve the post-provisioned upperdir."""
from pathlib import Path
import os
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[1]

MOCK_DOCKER = r"""#!/bin/sh
printf '%s\n' "$*" >> "$MOCK_DOCKER_LOG"
if [ "$1" = container ] && [ "$2" = inspect ]; then
  [ "$MOCK_STATE" != new ]
  exit $?
fi
if [ "$1" = inspect ]; then
  case "$3" in
    '{{.Config.Image}}') printf '%s\n' 'jetson-codex:jp72-base' ;;
    '{{range .Mounts}}{{println .Destination}}{{end}}')
      printf '%s\n' /opt/jetson-codex /workspace/projects
      if [ "$MOCK_STATE" != missing-cloud ]; then printf '%s\n' /cloud; fi ;;
    '{{.State.Running}}')
      if [ "$MOCK_STATE" = stopped ]; then echo false; else echo true; fi ;;
  esac
  exit 0
fi
exit 0
"""

def run(state: str):
    with tempfile.TemporaryDirectory(prefix="jetson-low-peak-") as tmp:
        home = Path(tmp)
        bins = home / "bin"
        bins.mkdir()
        docker_bin = bins / "docker"
        docker_bin.write_text(MOCK_DOCKER)
        docker_bin.chmod(0o755)
        log = home / "docker.log"
        log.touch()
        env = dict(os.environ, HOME=str(home), USER="dex", MOCK_STATE=state,
                   MOCK_DOCKER_LOG=str(log),
                   XDG_CONFIG_HOME=str(home / ".config"),
                   PATH=f"{bins}:{os.environ['PATH']}")
        result = subprocess.run(["bash", "./run-hardware.sh"], cwd=REPO,
                                capture_output=True, text=True, env=env, timeout=12)
        return result, log.read_text()

existing, log = run("running")
assert existing.returncode == 0, (existing.stdout, existing.stderr)
assert "already running" in existing.stdout
assert "run " not in log and "rm " not in log and "start " not in log

stopped, log = run("stopped")
assert stopped.returncode == 0, (stopped.stdout, stopped.stderr)
assert "start jetson-codex" in log
assert "rm " not in log and "run " not in log

missing, log = run("missing-cloud")
assert missing.returncode != 0
assert "lacks /cloud" in missing.stderr
assert "rm " not in log and "run " not in log and "start " not in log

new, log = run("new")
assert new.returncode == 0, (new.stdout, new.stderr)
assert "target=/cloud,bind-propagation=rslave" in log
assert "target=/workspace/projects,bind-propagation=rslave" in log
assert "target=/opt/jetson-codex,readonly" in log
assert "rm " not in log

print("PASS: existing container retained, stopped container restarted, "
      "missing mount refused, new /cloud binding created")
