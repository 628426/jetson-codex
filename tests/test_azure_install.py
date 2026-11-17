#!/usr/bin/env python3
"""Offline regression tests for Azure CLI DNS failure recovery and safe keyring writes."""
import os
from pathlib import Path
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[1]
EXPECTED_FPR = "BC528686B50D79E339D3721CEB3E94ADBE1229CF"

FAKE_CURL = r"""#!/bin/sh
printf 'curl %s\n' "$*" >> "$MOCK_NET_LOG"
output=''
while [ "$#" -gt 0 ]; do
  if [ "$1" = '--output' ]; then
    shift
    output="$1"
  fi
  shift
done
if [ "$MOCK_FETCH" = 'fail' ]; then
  echo 'curl: (6) Could not resolve host: packages.microsoft.com' >&2
  exit 6
fi
printf 'FAKE-ARMOURED-MICROSOFT-KEY\n' > "$output"
exit 0
"""
FAKE_GPG = r"""#!/bin/sh
case " $* " in
  *" --show-keys "*)
    printf 'fpr:::::::::%s:\n' "$MOCK_FINGERPRINT"
    ;;
  *)
    outfile=''
    while [ "$#" -gt 0 ]; do
      if [ "$1" = '-o' ]; then shift; outfile="$1"; fi
      shift
    done
    [ -n "$outfile" ] || exit 2
    printf 'BINARY-MICROSOFT-KEY\n' > "$outfile"
    ;;
esac
exit 0
"""
FAKE_APT = r"""#!/bin/sh
printf 'apt-get %s\n' "$*" >> "$MOCK_APT_LOG"
case " $* " in
  *" install azure-cli"*) : > "$MOCK_INSTALLED" ;;
esac
exit 0
"""
FAKE_AZ = r"""#!/bin/sh
[ -f "$MOCK_INSTALLED" ] || exit 127
[ "$1" != --version ] || printf 'azure-cli mock\n'
exit 0
"""
FAKE_GETENT = "#!/bin/sh\nexit 2\n"


def executable(path: Path, text: str):
    path.write_text(text)
    path.chmod(0o755)


with tempfile.TemporaryDirectory(prefix="azure-install-test-") as tmp:
    root = Path(tmp)
    bins = root / "bin"
    bins.mkdir()
    for name, code in [
        ("curl", FAKE_CURL), ("gpg", FAKE_GPG),
        ("apt-get", FAKE_APT), ("az", FAKE_AZ), ("getent", FAKE_GETENT)
    ]:
        executable(bins / name, code)

    keyrings = root / "keyrings"
    sources = root / "sources"
    keyrings.mkdir()
    sources.mkdir()
    keyring = keyrings / "microsoft-azure.gpg"
    sourcelist = sources / "azure-cli.list"
    keyring.write_text("PRESERVE GOOD EXISTING KEY\n")
    sourcelist.write_text("PRESERVE GOOD EXISTING REPO\n")
    network_log = root / "net.log"
    apt_log = root / "apt.log"
    network_log.touch()
    apt_log.touch()
    installed = root / "azure-installed"
    env = dict(os.environ,
               PATH=f"{bins}:{os.environ['PATH']}",
               AZURE_KEYRING_DIR=str(keyrings),
               AZURE_SOURCES_DIR=str(sources),
               MOCK_FETCH="fail",
               MOCK_FINGERPRINT=EXPECTED_FPR,
               MOCK_NET_LOG=str(network_log),
               MOCK_APT_LOG=str(apt_log),
               MOCK_INSTALLED=str(installed))

    def run():
        return subprocess.run(
            ["bash", "install-azure-cli.sh"], cwd=REPO, env=env,
            capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=12)

    failed = run()
    assert failed.returncode != 0, (failed.stdout, failed.stderr)
    assert "Could not resolve host" in failed.stderr
    assert "DNS/HTTPS failed" in failed.stdout
    assert keyring.read_text() == "PRESERVE GOOD EXISTING KEY\n"
    assert sourcelist.read_text() == "PRESERVE GOOD EXISTING REPO\n"
    assert apt_log.read_text() == ""
    assert "--retry-all-errors" in network_log.read_text()
    assert "--output" in network_log.read_text()
    assert not installed.exists()

    env["MOCK_FETCH"] = "ok"
    env["MOCK_FINGERPRINT"] = "0000000000000000000000000000000000000000"
    invalid_key = run()
    assert invalid_key.returncode != 0, (invalid_key.stdout, invalid_key.stderr)
    assert "did not match" in invalid_key.stderr
    assert keyring.read_text() == "PRESERVE GOOD EXISTING KEY\n"
    assert sourcelist.read_text() == "PRESERVE GOOD EXISTING REPO\n"
    assert apt_log.read_text() == ""

    env["MOCK_FINGERPRINT"] = EXPECTED_FPR
    fixed = run()
    assert fixed.returncode == 0, (fixed.stdout, fixed.stderr)
    assert keyring.read_text() == "BINARY-MICROSOFT-KEY\n"
    assert "packages.microsoft.com/repos/azure-cli/" in sourcelist.read_text()
    assert f"signed-by={keyring}" in sourcelist.read_text()
    assert installed.exists()
    assert "APT::Update::Error-Mode=any" in apt_log.read_text()
    assert "install azure-cli" in apt_log.read_text()
    before_apt = apt_log.read_text()
    before_net = network_log.read_text()

    again = run()
    assert again.returncode == 0, (again.stdout, again.stderr)
    assert "already installed; no APT changes" in again.stdout
    assert before_apt == apt_log.read_text()
    assert before_net == network_log.read_text()

print("PASS: Azure DNS failure preserves keys, fingerprint validation, resume and no-op rerun")
