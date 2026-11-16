#!/usr/bin/env python3
"""Mock complete uninstall under a temporary HOME; no real Docker/cloud touched."""
import os
from pathlib import Path
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[1]
FAKE_DOCKER = r"""#!/bin/sh
printf '%s\n' "$*" >> "$TEST_DOCKER_LOG"
if [ "$1" = "info" ]; then exit 0; fi
if [ "$1" = "container" ] && [ "$2" = "inspect" ]; then
  [ "$MOCK_HAS_DOCKER" = "yes" ]; exit $?
fi
if [ "$1" = "inspect" ]; then
  if [ "$MOCK_FOREIGN" = "yes" ]; then
    printf 'unrelated/important:latest\n'
  else
    printf 'jetson-codex:jp72-base\n'
  fi
  exit 0
fi
if [ "$1" = "image" ] && [ "$2" = "inspect" ]; then
  [ "$MOCK_HAS_DOCKER" = "yes" ]; exit $?
fi
if [ "$1" = "volume" ] && [ "$2" = "inspect" ]; then
  [ "$MOCK_HAS_DOCKER" = "yes" ]; exit $?
fi
exit 0
"""
FAKE_SYSTEMCTL = r"""#!/bin/sh
printf '%s\n' "$*" >> "$TEST_SYSTEMCTL_LOG"
if [ "$2" = "is-active" ]; then exit 1; fi
exit 0
"""

def executable(path: Path, source: str):
    path.write_text(source)
    path.chmod(0o755)

def run(confirm: bool, foreign: bool = False, present: bool = True):
    with tempfile.TemporaryDirectory(prefix="jetson-uninstall-test-") as tmp:
        home = Path(tmp)
        checkout = home / "jetson-codex"
        checkout.mkdir()
        subprocess.run(["git", "init", "-q", str(checkout)], check=True)
        subprocess.run(["git", "-C", str(checkout), "remote", "add",
                        "origin", "https://github.com/628426/jetson-codex.git"], check=True)
        source = checkout / "workspace/source"
        source.mkdir(parents=True)
        (source / "project.txt").write_text("delete this local work\n")
        config = home / ".config/jetson-codex"
        config.mkdir(parents=True)
        (config / "storage.env").write_text("RCLONE_REMOTE=onedrive\n")
        user_systemd = home / ".config/systemd/user"
        user_systemd.mkdir(parents=True)
        (user_systemd / "jetson-codex-cloud.service").write_text(
            "[Unit]\nDescription=Jetson Codex cloud project filesystem\n")
        cache = home / ".cache/jetson-codex/rclone"
        cache.mkdir(parents=True)
        (cache / "cache-file").write_text("cache\n")
        cloud_mount = home / "jetson-codex-cloud"
        cloud_mount.mkdir()
        shared_rclone = home / ".config/rclone"
        shared_rclone.mkdir(parents=True)
        (shared_rclone / "rclone.conf").write_text("preserve this\n")
        unrelated = home / "other"
        unrelated.mkdir()
        (unrelated / "important.txt").write_text("preserve me\n")

        bins = home / "bin"
        bins.mkdir()
        executable(bins / "docker", FAKE_DOCKER)
        executable(bins / "systemctl", FAKE_SYSTEMCTL)
        executable(bins / "mountpoint", "#!/bin/sh\nexit 1\n")
        docker_log = home / "docker.log"
        docker_log.touch()
        systemctl_log = home / "systemctl.log"
        systemctl_log.touch()
        env = dict(os.environ,
                   HOME=str(home), USER="dex",
                   TEST_DOCKER_LOG=str(docker_log),
                   TEST_SYSTEMCTL_LOG=str(systemctl_log),
                   MOCK_FOREIGN="yes" if foreign else "no",
                   MOCK_HAS_DOCKER="yes" if present else "no",
                   PATH=f"{bins}:{os.environ['PATH']}")
        if confirm:
            env["JETSON_CODEX_UNINSTALL_CONFIRM"] = "ERASE jetson-codex"
        else:
            env.pop("JETSON_CODEX_UNINSTALL_CONFIRM", None)

        result = subprocess.run(["bash", "./uninstall.sh"], cwd=REPO,
                                env=env, stdin=subprocess.DEVNULL,
                                capture_output=True, text=True, timeout=15)
        log = docker_log.read_text()
        service_log = systemctl_log.read_text()
        if not confirm or foreign:
            assert result.returncode != 0, (result.stdout, result.stderr)
            assert checkout.is_dir() and config.is_dir()
            assert "rm -f jetson-codex" not in log
            assert "volume rm" not in log
        else:
            assert result.returncode == 0, (result.stdout, result.stderr)
            assert not checkout.exists()
            assert not config.exists()
            assert not cache.exists()
            assert not cloud_mount.exists()
            assert "rm -f jetson-codex" in log
            assert "buildx prune --all --force" in log
            assert log.count("volume rm") == 6
            assert "stop jetson-codex-cloud.service" in service_log
            assert "disable jetson-codex-cloud.service" in service_log
        assert (shared_rclone / "rclone.conf").read_text() == "preserve this\n"
        assert (unrelated / "important.txt").read_text() == "preserve me\n"
        return result

run(confirm=False)
run(confirm=True, foreign=True)
run(confirm=True)
print("PASS: uninstall confirmation, ownership checks, complete local wipe and shared-data preservation")
