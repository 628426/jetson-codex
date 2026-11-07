#!/usr/bin/env bash
# Bootstrap or update 628426/jetson-codex on a Jetson Orin.
# Single entry point: host bootstrap, install/repair, and integrated health checks.
# Uses the invoking account for persistent OAuth and workspace ownership.
set -Eeuo pipefail

REPO_URL="https://github.com/628426/jetson-codex.git"
REPO_DIR="${JETSON_CODEX_DIR:-${HOME:?HOME must be set}/jetson-codex}"
IMAGE=""
DOCKERFILE=""
CONTAINER="jetson-codex"
MODE="hardware"
BUILD=0
NEED_NVIDIA_RUNTIME=0

say() { printf '[jetson-codex] %s\n' "$*"; }
fail() { printf '[jetson-codex] ERROR: %s\n' "$*" >&2; exit 1; }

(( $# == 0 )) || fail "No parameters supported. Run install.sh without arguments."
[[ $EUID -ne 0 ]] || fail "Run as your normal account, not sudo."
[[ "$(uname -s)" == "Linux" ]] || fail "Linux is required."
[[ -f /etc/os-release ]] || fail "Cannot identify host OS."
. /etc/os-release
[[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "24.04" ]] || fail "Expected Ubuntu 24.04; found ${PRETTY_NAME:-unknown}."
[[ -f /etc/nv_tegra_release ]] || fail "Missing /etc/nv_tegra_release; cannot safely select JetPack image."
l4t="$(sed -nE 's/^# R([0-9]+) \(release\), REVISION: ([0-9]+\.[0-9]+).*/\1.\2/p' /etc/nv_tegra_release | head -n 1)"
case "$l4t" in
  39.2.0)
    DOCKERFILE="Dockerfile.jetpack-7.2.0"
    IMAGE="jetson-codex:jp72-full"
    ;;
  *) fail "Unsupported L4T $l4t. No Dockerfile selected; refusing to guess compatibility." ;;
esac
export JETSON_CODEX_DOCKERFILE="$DOCKERFILE" JETSON_CODEX_IMAGE="$IMAGE"
say "Detected L4T $l4t; selected $DOCKERFILE ($IMAGE)"
case "$(uname -m)" in
  aarch64|arm64) ;;
  *) fail "This image is for a native ARM64 Jetson. Host architecture is $(uname -m)." ;;
esac

for bin in git docker; do
  command -v "$bin" >/dev/null 2>&1 || fail "Missing prerequisite: $bin"
done
docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 is required (docker compose)."
if ! docker info >/dev/null 2>&1; then
  if ! sudo docker info >/dev/null 2>&1; then
    fail "Docker daemon unavailable, including via sudo. Check Docker service."
  fi
  if ! id -nG "$USER" | tr ' ' '\n' | grep -Fxq docker; then
    say "Granting $USER Docker access (root-equivalent)."
    sudo usermod -aG docker "$USER"
  fi
  say "Activating Docker group for this install without requiring a new SSH session."
  [[ "${JETSON_CODEX_GROUP_REEXEC:-}" != "1" ]] || fail "Docker group activation failed."
  export JETSON_CODEX_GROUP_REEXEC=1
  exec sg docker -c 'curl -fsSL https://raw.githubusercontent.com/628426/jetson-codex/main/install.sh | bash'
fi
if ! docker info --format '{{json .Runtimes}}' | grep -q '"nvidia"'; then
  say "NVIDIA Docker runtime missing. Installing/configuring automatically."
  # Run the host setup from the trusted repository checkout after it is fetched.
  NEED_NVIDIA_RUNTIME=1
else
  NEED_NVIDIA_RUNTIME=0
fi

if [[ -e "$REPO_DIR" ]]; then
  [[ -d "$REPO_DIR/.git" ]] || fail "$REPO_DIR exists but is not the expected Git checkout."
  origin="$(git -C "$REPO_DIR" remote get-url origin)" || fail "Could not read repo origin."
  case "$origin" in
    https://github.com/628426/jetson-codex|https://github.com/628426/jetson-codex.git|git@github.com:628426/jetson-codex.git|ssh://git@github.com/628426/jetson-codex.git) ;;
    *) fail "Checkout origin is '$origin', not 628426/jetson-codex. Refusing to modify it." ;;
  esac
  branch="$(git -C "$REPO_DIR" branch --show-current)"
  [[ "$branch" == "main" ]] || fail "Checkout is on '$branch', not main. Switch to main first."
  git -C "$REPO_DIR" diff --quiet && git -C "$REPO_DIR" diff --cached --quiet || fail "Tracked files have local changes. Commit/stash them before updating."
  say "Updating existing checkout: $REPO_DIR"
  git -C "$REPO_DIR" pull --ff-only origin main
else
  say "Cloning $REPO_URL into $REPO_DIR"
  mkdir -p "$(dirname "$REPO_DIR")"
  git clone --branch main --single-branch "$REPO_URL" "$REPO_DIR"
fi

cd "$REPO_DIR"
if (( NEED_NVIDIA_RUNTIME )); then
  say "Installing/configuring NVIDIA Container Toolkit using existing APT repositories."
  if ! command -v nvidia-ctk >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y nvidia-container-toolkit || fail "Toolkit unavailable in configured repositories."
  fi
  sudo nvidia-ctk runtime configure --runtime=docker
  sudo systemctl restart docker
  docker info --format '{{json .Runtimes}}' | grep -q '"nvidia"' || fail "NVIDIA runtime still missing."
fi
if true; then
  if [[ -f /etc/apt/apt.conf.d/20auto-upgrades ]] && grep -q 'APT::Periodic::Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades; then
    say "Ubuntu unattended security updates already configured."
  else
    say "Installing Ubuntu unattended security updates."
    sudo apt-get update
    sudo apt-get install -y unattended-upgrades
    printf '%s\n' 'APT::Periodic::Update-Package-Lists "1";' 'APT::Periodic::Unattended-Upgrade "1";' 'APT::Periodic::AutocleanInterval "7";' | sudo tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null
    sudo systemctl enable --now apt-daily.timer apt-daily-upgrade.timer
  fi
fi
[[ -f "$DOCKERFILE" ]] || fail "Selected Dockerfile missing: $DOCKERFILE"
mkdir -p workspace workspace/source "$HOME/jetson-codex-cloud"
if [[ ! -f "${XDG_CONFIG_HOME:-$HOME/.config}/jetson-codex/storage.env" ]]; then
  say "Cloud storage is not configured."
  if [[ -r /dev/tty && -w /dev/tty ]]; then
    printf "Configure OneDrive/Google Drive now? [y/N] " >/dev/tty
    IFS= read -r answer </dev/tty || answer=n
    if [[ "$answer" =~ ^[Yy]$ ]]; then
      bash ./configure-storage.sh || say "Cloud setup incomplete; you can retry later."
    fi
  fi
fi
if [[ -f "${XDG_CONFIG_HOME:-$HOME/.config}/jetson-codex/storage.env" ]]; then
  bash ./configure-storage.sh --mount || say "Cloud mount unavailable; health check will report this."
fi
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  BUILD=1
fi
if (( BUILD )); then
  say "Building full ARM64 JetPack + Codex image; this is a large build."
  if ! docker compose --progress plain build; then
    fail "Docker build failed. Check the output above and README troubleshooting; the existing container was not changed."
  fi
else
  docker image inspect "$IMAGE" >/dev/null 2>&1 || fail "--no-build requested, but $IMAGE is missing."
  say "Reusing existing image: $IMAGE"
fi

if docker container inspect "$CONTAINER" >/dev/null 2>&1; then
  current_image="$(docker inspect --format '{{.Config.Image}}' "$CONTAINER")"
  [[ "$current_image" == "$IMAGE" ]] || fail "A container named '$CONTAINER' already exists using '$current_image'. Not replacing an unrelated container."
  if [[ "$MODE" == "hardware" ]]; then
    if (( BUILD )) || ! docker ps --format '{{.Names}}' | grep -Fxq "$CONTAINER" || ! docker exec "$CONTAINER" test -d /workspace/projects; then
      say "Refreshing hardware container (persistent volumes retained)."
      docker rm -f "$CONTAINER" >/dev/null
    else
      say "Container already running; leaving it untouched."
    fi
  else
    compose_service="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' "$CONTAINER" 2>/dev/null || true)"
    if [[ "$compose_service" != "jetson-codex" ]]; then
      say "Replacing hardware-run container with Compose-managed GPU-only container (volumes retained)."
      docker rm -f "$CONTAINER" >/dev/null
    fi
  fi
fi

if [[ "$MODE" == "hardware" ]]; then
  if ! docker container inspect "$CONTAINER" >/dev/null 2>&1; then
    say "Starting GPU + detected hardware devices via run-hardware.sh"
    bash ./run-hardware.sh
  fi
else
  say "Starting GPU-only Compose service"
  docker compose up -d --no-build
fi

if ! docker ps --filter "name=^/$CONTAINER$" --format '{{.Names}}' | grep -Fxq "$CONTAINER"; then
  fail "$CONTAINER is not running; inspect 'docker logs $CONTAINER'."
fi

# User-requested full trust: Codex may execute commands without approval prompts.
# Persist in the existing Codex auth volume; keep the container boundary.
say "Configuring Codex full trust (no approvals, unrestricted container filesystem)"
docker exec "$CONTAINER" python3 /opt/jetson-codex/configure-full-trust.py \
  || fail "Could not configure Codex full-trust defaults."

# Interactive authentication requires a real TTY. curl | bash does not always
# provide stdin to the script, so attach docker exec to /dev/tty explicitly.
say "Checking existing Codex login"
if docker exec "$CONTAINER" codex login status >/dev/null 2>&1; then
  say "Codex is already authenticated; skipping device login."
else
  say "Codex is not authenticated."
  if [[ -r /dev/tty && -w /dev/tty ]]; then
    say "Starting device login. Open https://auth.openai.com/codex/device and enter the code displayed below."
    if ! docker exec -it "$CONTAINER" codex login --device-auth </dev/tty >/dev/tty 2>&1; then
      say "Codex login was not completed; retry with: docker exec -it jetson-codex codex login --device-auth"
    fi
  else
    say "No interactive terminal available. Run: docker exec -it jetson-codex codex login --device-auth"
  fi
fi

# Link GitHub once if the user has a terminal; credentials persist in named volume.
if docker exec "$CONTAINER" gh auth status >/dev/null 2>&1; then
  say "GitHub already linked; skipping OAuth."
elif [[ -r /dev/tty && -w /dev/tty ]]; then
  printf '\n========================================================\n' >/dev/tty
  printf ' GITHUB LINKING\n Open: https://github.com/login/device\n' >/dev/tty
  printf ' Enter the one-time code shown by GitHub CLI.\n' >/dev/tty
  printf '========================================================\n' >/dev/tty
  if docker exec -it "$CONTAINER" gh auth login --hostname github.com --git-protocol https --web </dev/tty >/dev/tty 2>&1; then
    docker exec "$CONTAINER" gh auth setup-git || say "GitHub authenticated; git credential helper setup needs attention."
  else
    say "GitHub linking skipped or failed; retry: docker exec -it jetson-codex gh auth login --hostname github.com --git-protocol https --web"
  fi
else
  say "GitHub not linked; no interactive terminal available."
fi

say "Running health checks"
if docker exec "$CONTAINER" codex --version >/dev/null 2>&1 \
  && docker exec "$CONTAINER" python3 -c 'import pathlib,tomllib; c=tomllib.loads((pathlib.Path.home()/".codex/config.toml").read_text()); assert c.get("approval_policy")=="never" and c.get("sandbox_mode")=="danger-full-access"' \
  && docker info --format '{{json .Runtimes}}' | grep -q '"nvidia"'; then
  say "Health OK: Codex executable, full trust and NVIDIA runtime."
else
  fail "Post-install health check failed."
fi

cat <<'DONE'

[jetson-codex] Persistent container is running.

Enter it:
  docker exec -it jetson-codex bash -l

Codex device login (if still required):
  docker exec -it jetson-codex codex login --device-auth
  https://auth.openai.com/codex/device

GitHub CLI login (separate, once):
  docker exec -it jetson-codex gh auth login --hostname github.com --git-protocol https --web
  https://github.com/login/device
  docker exec jetson-codex gh auth setup-git

Run Codex:
  docker exec -it jetson-codex codex

Saved credentials and full-trust settings survive container recreation and image rebuilds.
WARNING: Codex can execute commands without approval. This container uses host
networking and has access to mapped hardware and your mounted workspace.
DONE
