#!/usr/bin/env bash
# Jetson Orin R39.2: toolkit v1.19.0 (and earlier) can panic on the Orin CUDA
# compat ELF header before Docker starts. NVIDIA fixed it in v1.19.1.
# Reconcile only the four NVIDIA Container Toolkit packages from EXISTING
# host APT repositories. Never change the host JetPack BSP, driver or CUDA.
set -Eeuo pipefail

say() { printf '[nvidia-toolkit] %s\n' "$*"; }
fail() { say "ERROR: $*" >&2; exit 1; }
minimum=1.19.1
packages=(nvidia-container-toolkit nvidia-container-toolkit-base
          libnvidia-container-tools libnvidia-container1)

command -v dpkg-query >/dev/null || fail "dpkg-query missing."
command -v dpkg >/dev/null || fail "dpkg missing."
command -v apt-cache >/dev/null || fail "apt-cache missing."

needs_repair=0
for pkg in "${packages[@]}"; do
  version="$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || true)"
  if [[ -n "$version" ]] && dpkg --compare-versions "$version" ge "$minimum"; then
    say "$pkg $version: OK."
  else
    say "$pkg ${version:-missing}: needs >= $minimum (Orin CUDA compat crash fix)."
    needs_repair=1
  fi
done

if (( ! needs_repair )); then
  say "All NVIDIA Container Toolkit packages meet >= $minimum; no changes."
  exit 0
fi

# APT indexes might be stale. Only update if the package state is insufficient.
say "Checking available NVIDIA Container Toolkit fixes from configured APT sources."
sudo apt-get update || fail "Cannot refresh existing APT sources."
pinned=()
expected=""
for pkg in "${packages[@]}"; do
  candidate="$(apt-cache policy "$pkg" | awk '/^[[:space:]]*Candidate: / {print $2; exit}')"
  [[ -n "$candidate" && "$candidate" != "(none)" ]] \
    || fail "No repository candidate for $pkg; not changing NVIDIA packages."
  dpkg --compare-versions "$candidate" ge "$minimum" \
    || fail "$pkg repository candidate $candidate is below NVIDIA's fixed $minimum. Not changing packages."
  # NVIDIA publishes the toolkit and libnvidia-container as a unified release.
  # Mixed toolkit generations can break hooks and CUDA driver injection.
  if [[ -n "$expected" && "$candidate" != "$expected" ]]; then
    fail "Mixed NVIDIA toolkit candidates: $pkg=$candidate, expected $expected. No changes made."
  fi
  expected="$candidate"
  pinned+=("$pkg=$candidate")
done

# An APT transaction removing JetPack, Docker or unrelated packages is unsafe.
# Abort rather than approving it with -y. The user can inspect and resolve.
simulation="$(apt-get -s --no-install-recommends install "${pinned[@]}")" \
  || fail "APT could not resolve a compatible NVIDIA toolkit transaction."
if grep -Eq '^(Remv|Purg) ' <<< "$simulation"; then
  printf '%s\n' "$simulation" >&2
  fail "APT would remove existing packages. Refusing NVIDIA toolkit update."
fi
say "Installing complete NVIDIA toolkit family ${expected}; no driver/BSP upgrade."
sudo apt-get install -y --no-install-recommends "${pinned[@]}" \
  || fail "NVIDIA toolkit package installation failed."

for pkg in "${packages[@]}"; do
  version="$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || true)"
  [[ -n "$version" ]] && dpkg --compare-versions "$version" ge "$minimum" \
    || fail "$pkg is still older than $minimum; Docker startup remains blocked."
done
say "NVIDIA Container Toolkit updated and verified. Docker's next start will invoke the updated CDI hook."
