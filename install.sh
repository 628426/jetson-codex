#!/usr/bin/env bash
# Bootstrap or update 628426/jetson-codex on a Jetson Orin.
# Single entry point: host bootstrap, install/repair, and read-only health checks.
# User creation is opt-in; never silently migrate an existing installation.
set -Eeuo pipefail

REPO_URL="https://github.com/628426/jetson-codex.git"
REPO_DIR="${JETSON_CODEX_DIR:-${HOME:?HOME must be set}/jetson-codex}"
IMAGE=""
DOCKERFILE=""
CONTAINER="jetson-codex"
MODE="hardware"
BUILD=0
FORCE_BUILD=0
HEALTH_ONLY=0
NO_BUILD=0
SKIP_UPDATES=0
SERVICE_USER=0
CURRENT_USER=0
INSTALL_ARGS=("$@")

say() { printf '[jetson-codex] %s\n' "$*"; }
fail() { printf '[jetson-codex] ERROR: %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'USAGE'
Usage: install.sh [--service-user | --current-user] [--hardware | --gpu-only] [--rebuild] [--check]

On a Jetson Orin, clone/update the public repo, build its ARM64 image,
and start a named persistent container.

  --service-user  Create/use dedicated jetson-codex account (opt-in).
  --current-user  Install under the current user (default for existing installs).
  --hardware    Default. Map the detected camera, I2C, GPIO and USB serial
                device nodes and the CSI Argus socket if present, plus GPU.
  --gpu-only    Use Docker Compose, with NVIDIA GPU but no extra device nodes.
  --no-build    Require an existing image; do not build.
  --rebuild     Force an image rebuild even when already present.
  --check       Run read-only health checks without changing anything.
  --skip-updates  Do not configure Ubuntu unattended security updates.
  -h, --help    Show this help.

Optional: JETSON_CODEX_DIR overrides ~/jetson-codex.

Note: an existing 'jetson-codex' container may be recreated to deploy
an updated image. The /workspace bind mount and authentication volumes
are retained. Active processes inside the old container will stop.
USAGE
}

while (( $# )); do
  case "$1" in
    --hardware) MODE="hardware" ;;
    --gpu-only) MODE="compose" ;;
    --no-build) NO_BUILD=1 ;;
    --rebuild) FORCE_BUILD=1 ;;
    --check) HEALTH_ONLY=1 ;;
    --skip-updates) SKIP_UPDATES=1 ;;
    --service-user) SERVICE_USER=1 ;;
    --current-user) CURRENT_USER=1 ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown argument: $1 (use --help)" ;;
  esac
  shift
done

[[ $EUID -ne 0 ]] || fail "Run as a normal user, not sudo. The installer elevates only host setup steps."
(( SERVICE_USER && CURRENT_USER )) && fail "Choose --service-user or --current-user, not both."
if (( SERVICE_USER )) && [[ "${USER:-}" != "jetson-codex" ]]; then
  command -v sudo >/dev/null || fail "sudo is required for dedicated account setup."
  if ! id jetson-codex >/dev/null 2>&1; then
    say "Creating dedicated jetson-codex account (no password login)."
    sudo useradd --create-home --shell /bin/bash --user-group jetson-codex
    sudo passwd -l jetson-codex >/dev/null
  fi
  # Docker group is root-equivalent. Explicit --service-user authorises it.
  if ! id -nG jetson-codex | tr ' ' '\n' | grep -Fxq docker; then
    say "Granting dedicated account Docker access (root-equivalent)."
    sudo usermod -aG docker jetson-codex
  fi
  # Host-level changes must be completed by the invoking sudo-capable user.
  if ! sudo docker info --format '{{json .Runtimes}}' | grep -q '"nvidia"'; then
    if ! command -v nvidia-ctk >/dev/null 2>&1; then
      sudo apt-get update
      sudo apt-get install -y nvidia-container-toolkit
    fi
    sudo nvidia-ctk runtime configure --runtime=docker
    sudo systemctl restart docker
  fi
  if (( ! SKIP_UPDATES )); then
    if ! grep -q 'APT::Periodic::Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null; then
      sudo apt-get update
      sudo apt-get install -y unattended-upgrades
      printf '%s\n' 'APT::Periodic::Update-Package-Lists "1";' 'APT::Periodic::Unattended-Upgrade "1";' 'APT::Periodic::AutocleanInterval "7";' | sudo tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null
      sudo systemctl enable --now apt-daily.timer apt-daily-upgrade.timer
    fi
  fi
  say "Continuing under dedicated account; OAuth and files belong to jetson-codex."
  exec sudo -H -u jetson-codex bash -c 'curl -fsSL https://raw.githubusercontent.com/628426/jetson-codex/main/install.sh | bash -s -- --current-user --skip-updates' 
fi
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

healthcheck() {
  local failures=0
  check() { if "$@" >/dev/null 2>&1; then say "OK: $*"; else say "FAIL: $*"; failures=$((failures+1)); fi; }
  check docker info
  check docker compose version
  if docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q '"nvidia"'; then say 'OK: NVIDIA runtime registered'; else say 'FAIL: NVIDIA runtime missing'; failures=$((failures+1)); fi
  check docker container inspect jetson-codex
  check docker exec jetson-codex codex --version
  check docker exec jetson-codex codex login status
  check docker exec jetson-codex python3 -c 'import pathlib,tomllib; c=tomllib.loads((pathlib.Path.home()/".codex/config.toml").read_text()); assert c.get("approval_policy")=="never" and c.get("sandbox_mode")=="danger-full-access"'
  check docker exec jetson-codex gh --version
  if [[ -f "${XDG_CONFIG_HOME:-$HOME/.config}/jetson-codex/storage.env" ]]; then
    source "${XDG_CONFIG_HOME:-$HOME/.config}/jetson-codex/storage.env"
    check mountpoint -q "$RCLONE_MOUNT"
    check timeout 20 rclone lsf "$RCLONE_SOURCE" --max-depth 1
  fi
  if [[ -f /etc/apt/apt.conf.d/20auto-upgrades ]] && grep -q 'APT::Periodic::Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades; then
    say "OK: unattended security updates configured"
  else
    say "WARN: unattended security updates not configured"
  fi
  (( failures == 0 )) || fail "$failures health checks failed."
  say "All required health checks passed."
}
if (( HEALTH_ONLY )); then healthcheck; exit 0; fi

for bin in git docker; do
  command -v "$bin" >/dev/null 2>&1 || fail "Missing prerequisite: $bin"
done
docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 is required (docker compose)."
if ! docker info >/dev/null 2>&1; then
  if ! id -nG "$USER" | tr ' ' '\n' | grep -Fxq docker; then
    fail "User $USER lacks Docker access. Run: sudo usermod -aG docker $USER ; then reconnect SSH. Or run installer with --service-user."
  fi
  fail "Docker unavailable in this session. Reconnect SSH after group changes; check systemctl status docker."
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
if (( ! SKIP_UPDATES )); then
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
if (( FORCE_BUILD && NO_BUILD )); then fail "Cannot combine --rebuild and --no-build"; fi
if (( FORCE_BUILD )); then BUILD=1; fi
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  (( NO_BUILD )) && fail "--no-build requested but image $IMAGE does not exist."
  BUILD=1
fi
if (( BUILD )); then
  say "Building full ARM64 JetPack + Codex image; this is a large build."
  if ! docker compose build --progress=plain; then
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
healthcheck || say "Health checks reported issues; see output above."

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
