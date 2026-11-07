#!/usr/bin/env bash
# Bootstrap or update 628426/jetson-codex on a Jetson Orin.
# This script deliberately does not install host packages, modify Docker daemon
# configuration, or put ChatGPT/GitHub tokens in source files.
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

say() { printf '[jetson-codex] %s\n' "$*"; }
fail() { printf '[jetson-codex] ERROR: %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'USAGE'
Usage: install.sh [--hardware | --gpu-only] [--rebuild] [--check] [--no-build]

On a Jetson Orin, clone/update the public repo, build its ARM64 image,
and start a named persistent container.

  --hardware    Default. Map the detected camera, I2C, GPIO and USB serial
                device nodes and the CSI Argus socket if present, plus GPU.
  --gpu-only    Use Docker Compose, with NVIDIA GPU but no extra device nodes.
  --no-build    Require an existing image; do not build.\n  --rebuild     Force an image rebuild even when already present.\n  --check       Run read-only health checks without changing anything.
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
    --no-build) BUILD=0 ;;\n    --rebuild) FORCE_BUILD=1 ;;\n    --check) HEALTH_ONLY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown argument: $1 (use --help)" ;;
  esac
  shift
done

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

if (( HEALTH_ONLY )); then
  [[ -f "$REPO_DIR/healthcheck.sh" ]] || fail "Health checker missing; run installer normally once."
  exec bash "$REPO_DIR/healthcheck.sh"
fi

for bin in git docker; do
  command -v "$bin" >/dev/null 2>&1 || fail "Missing prerequisite: $bin"
done
docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 is required (docker compose)."
docker info >/dev/null 2>&1 || fail "Cannot connect to Docker. Check daemon and Docker group membership."
if ! docker info --format '{{json .Runtimes}}' | grep -q '"nvidia"'; then
  fail "NVIDIA Docker runtime is not registered. Install/configure nvidia-container-toolkit on the host first."
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
if (( FORCE_BUILD )); then BUILD=1; fi
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then BUILD=1; fi
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
    if (( BUILD )) || ! docker ps --format '{{.Names}}' | grep -Fxq "$CONTAINER"; then
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

say "Running health checks"
bash ./healthcheck.sh || say "Health checks reported issues; see output above."

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
