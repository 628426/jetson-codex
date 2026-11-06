#!/usr/bin/env bash
# Bootstrap or update 628426/jetson-codex on a Jetson Orin.
# This script deliberately does not install host packages, modify Docker daemon
# configuration, or put ChatGPT/GitHub tokens in source files.
set -Eeuo pipefail

REPO_URL="https://github.com/628426/jetson-codex.git"
REPO_DIR="\${JETSON_CODEX_DIR:-\${HOME:?HOME must be set}/jetson-codex}"
IMAGE="jetson-codex:jp62-full"
CONTAINER="jetson-codex"
MODE="hardware"
BUILD=1

say() { printf '[jetson-codex] %s\n' "$*"; }
fail() { printf '[jetson-codex] ERROR: %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'USAGE'
Usage: install.sh [--hardware | --gpu-only] [--no-build]

On a Jetson Orin, clone/update the public repo, build its ARM64 image,
and start a named persistent container.

  --hardware    Default. Map the detected camera, I2C, GPIO and USB serial
                device nodes and the CSI Argus socket if present, plus GPU.
  --gpu-only    Use Docker Compose, with NVIDIA GPU but no extra device nodes.
  --no-build    Reuse the existing image instead of rebuilding it.
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
    --no-build) BUILD=0 ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown argument: $1 (use --help)" ;;
  esac
  shift
done

[[ "$(uname -s)" == "Linux" ]] || fail "Linux is required."
case "$(uname -m)" in
  aarch64|arm64) ;;
  *) fail "This image is for a native ARM64 Jetson. Host architecture is $(uname -m)." ;;
esac

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
mkdir -p workspace

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
    say "Replacing existing $CONTAINER container to refresh hardware devices/image (named volumes are retained)."
    docker rm -f "$CONTAINER" >/dev/null
  else
    compose_service="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' "$CONTAINER" 2>/dev/null || true)"
    if [[ "$compose_service" != "jetson-codex" ]]; then
      say "Replacing hardware-run container with Compose-managed GPU-only container (volumes retained)."
      docker rm -f "$CONTAINER" >/dev/null
    fi
  fi
fi

if [[ "$MODE" == "hardware" ]]; then
  say "Starting GPU + detected hardware devices via run-hardware.sh"
  bash ./run-hardware.sh
else
  say "Starting GPU-only Compose service"
  docker compose up -d --no-build
fi

if ! docker ps --filter "name=^/$CONTAINER$" --format '{{.Names}}' | grep -Fxq "$CONTAINER"; then
  fail "$CONTAINER is not running; inspect 'docker logs $CONTAINER'."
fi

cat <<'DONE'

[jetson-codex] Container is running and will restart after a Jetson reboot.

Enter it:
  docker exec -it jetson-codex bash -l

First-time authentication (inside container):
  codex login --device-auth
    Open https://auth.openai.com/codex/device and enter the code shown.
  gh auth login --hostname github.com --git-protocol https --web
    Open https://github.com/login/device and enter the code shown.
  gh auth setup-git

Then run: codex
Saved authentication survives image rebuilds and container recreation.
DONE
