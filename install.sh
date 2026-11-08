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
# Early storage preflight: free space on the Docker data-root filesystem.
# The new CUDA/cuDNN + TRT + standalone DeepStream image has not yet been
# measured on dexson. 24 GiB is an advisory build-headroom estimate, not a
# measured final size. Warn below twice that estimate, never auto-delete data.
check_docker_free_space() {
  local docker_root df_output free_kib free_gib
  local estimated_needed_gib=24
  local warning_threshold_gib=$((estimated_needed_gib * 2))
  docker_root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
  if [[ -z "$docker_root" ]]; then
    say "WARN: Cannot determine Docker data root for disk-space preflight."
    return 0
  fi
  if ! df_output="$(df -Pk "$docker_root" 2>/dev/null)"; then
    say "WARN: Cannot read free disk space at Docker data root ($docker_root)."
    return 0
  fi
  free_kib="$(printf '%s\n' "$df_output" | awk 'NR==2 {print $4}')"
  if [[ ! "$free_kib" =~ ^[0-9]+$ ]]; then
    say "WARN: Could not parse free space for Docker data root ($docker_root)."
    return 0
  fi
  free_gib=$((free_kib / 1024 / 1024))
  say "Docker storage: $docker_root | available: ${free_gib} GiB."
  say "Build-space estimate: ${estimated_needed_gib} GiB; 2x warning threshold: ${warning_threshold_gib} GiB."
  if (( free_kib < warning_threshold_gib * 1024 * 1024 )); then
    say "WARNING: Docker storage has under 2x the estimated build headroom (${free_gib} GiB < ${warning_threshold_gib} GiB)."
    say "CUDA SDK extraction may need more headroom. This is advisory; continuing installation."
  else
    say "Disk-space preflight: OK (at least 2x estimated build headroom)."
  fi
}
check_docker_free_space

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
# Cloud setup is a dependency when selected, not an optional best-effort task.
# NEVER start the multi-GB Docker build while requested OAuth is incomplete.
STORAGE_ENV="${XDG_CONFIG_HOME:-$HOME/.config}/jetson-codex/storage.env"
if [[ ! -f "$STORAGE_ENV" ]]; then
  say "Cloud storage is not configured."
  if [[ -r /dev/tty && -w /dev/tty ]]; then
    printf "Configure OneDrive/Google Drive now? [y/N] " >/dev/tty
    IFS= read -r answer </dev/tty || answer=n
    if [[ "$answer" =~ ^[Yy]$ ]]; then
      if [[ "${RCLONE_SSH_TUNNEL:-0}" == "1" ]]; then
        say "One-click OAuth tunnel detected. Complete the browser linking before the Docker build."
        bash ./configure-storage.sh || fail "Cloud setup failed or was interrupted. Docker build NOT started."
        [[ -f "$STORAGE_ENV" ]] || fail "Cloud credentials not saved. Docker build NOT started."
      else
        # The OAuth callback must use localhost:53682 on the browser PC.
        # Print a complete one-command SSH forward and STOP the build here.
        server_ip=""
        if [[ -n "${SSH_CONNECTION:-}" ]]; then
          read -r _client _port server_ip _server_port <<< "$SSH_CONNECTION"
        fi
        if [[ "$server_ip" != *.* ]]; then
          server_ip="$(hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++) if(index($i, ".")>0 && $i ~ /^[0-9]/) {print $i; exit}}')"
        fi
        server_ip="${server_ip:-$(hostname -s)}"
        printf '\n%s\n' 'PAUSED: To link your cloud account, run this in Windows PowerShell:' >/dev/tty
        printf 'ssh -tt -o ExitOnForwardFailure=yes -L 53682:127.0.0.1:53682 %s@%s %s\n' "$USER" "$server_ip" "'export RCLONE_SSH_TUNNEL=1; curl -fsSL https://raw.githubusercontent.com/628426/jetson-codex/main/install.sh | bash'" >/dev/tty
        printf '%s\n\n' 'Open the localhost link on your Windows PC. Docker will build after cloud login succeeds.' >/dev/tty
        say "Installer paused before Docker build. No existing image or container was changed."
        exit 0
      fi
    else
      say "Cloud storage explicitly declined. Continuing without cloud mounts."
    fi
  else
    say "No interactive terminal for optional cloud setup. Continuing without cloud mounts."
  fi
fi
if [[ -f "$STORAGE_ENV" ]]; then
  say "Testing cloud remote authentication and live FUSE mount before Docker."
  bash ./storage-health.sh ||
    fail "Cloud storage is unavailable. Repair it via the interactive menu; Docker build NOT started."
fi
# The one-command installer updates changed build inputs automatically.
# Do not rebuild for README-only changes, or on healthy no-op reruns.
BUILD_INPUTS=("$DOCKERFILE" "setup-versions.sh" "verify.sh" "entrypoint.sh" "configure-full-trust.py" "codex-connect.sh" "hardware-check.sh" "tensorrt-smoke.cpp")
for input in "${BUILD_INPUTS[@]}"; do
  [[ -f "$input" ]] || fail "Missing Docker build dependency: $input"
done
export JETSON_CODEX_BUILD_HASH="$(sha256sum "${BUILD_INPUTS[@]}" | sha256sum | awk '{print $1}')"
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  BUILD=1
else
  installed_hash="$(docker image inspect --format '{{index .Config.Labels "org.jetson-codex.build-hash"}}' "$IMAGE" 2>/dev/null || true)"
  if [[ "$installed_hash" != "$JETSON_CODEX_BUILD_HASH" ]]; then
    say "Docker build inputs changed; rebuilding with cached layers where possible."
    BUILD=1
  fi
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

# The existing container may predate support for the NVDEC/VIC/NVJPG
# character devices. Check the explicitly mapped host paths and refresh
# only if a required device is not listed in Docker's --device mappings.
explicit_devices_current() {
  local missing
  missing="$(comm -23 \
    <(bash ./hardware-check.sh --devices) \
    <(docker inspect --format '{{range .HostConfig.Devices}}{{println .PathOnHost}}{{end}}' "$CONTAINER" 2>/dev/null | LC_ALL=C sort -u))"
  [[ -z "$missing" ]]
}

hardware_health() {
  local hostlist dockerlist missingfile hostcount dockercount host_cuda docker_cuda
  hostlist="$(mktemp)"
  dockerlist="$(mktemp)"
  missingfile="$(mktemp)"
  say "Checking Jetson hardware on HOST (no host SDK packages needed)."
  bash ./hardware-check.sh --devices > "$hostlist"
  hostcount="$(wc -l < "$hostlist")"
  say "Host character devices selected for passthrough: $hostcount"
  if grep -E '/dev/nvhost-[^ ]*(nvdec|vic|nvjpg)' "$hostlist" >/dev/null; then
    say "Host NVIDIA multimedia engine nodes detected."
  else
    say "No named NVDEC/VIC/NVJPG nodes found on host; decoder execution test is decisive."
  fi
  if host_cuda="$(bash ./hardware-check.sh --cuda 2>&1)"; then
    say "Host $host_cuda"
  else
    say "Host CUDA driver probe unavailable: $host_cuda"
  fi
  if command -v gst-inspect-1.0 >/dev/null 2>&1 && command -v ffmpeg >/dev/null 2>&1; then
    say "Host media tools already present: running optional host decode test."
    if bash ./hardware-check.sh --video; then
      say "Host H.264 decode is operational."
    else
      say "Host H.264 decode test failed; container test will determine accessible hardware."
    fi
  else
    say "Host media applications not installed (intentionally lean); no host packages added."
  fi

  say "Checking same hardware inside DOCKER."
  docker exec "$CONTAINER" bash /opt/jetson-codex/hardware-check.sh --devices > "$dockerlist" \
    || fail "Cannot inventory the container hardware nodes."
  dockercount="$(wc -l < "$dockerlist")"
  say "Container matching hardware device nodes: $dockercount"
  comm -23 "$hostlist" "$dockerlist" > "$missingfile"
  if [[ -s "$missingfile" ]]; then
    say "ERROR: Host character devices not visible inside Docker:"
    sed 's/^/  MISSING: /' "$missingfile" >&2
    rm -f "$hostlist" "$dockerlist" "$missingfile"
    fail "Hardware passthrough incomplete. No blanket --privileged mode was enabled."
  fi
  rm -f "$hostlist" "$dockerlist" "$missingfile"
  say "PASS: Every selected host character device is visible inside Docker."
  if [[ -S /tmp/argus_socket ]] && ! docker exec "$CONTAINER" test -S /tmp/argus_socket; then
    fail "Host Argus camera socket is missing in Docker."
  fi
  if [[ -S /tmp/argus_socket ]]; then say "PASS: Argus camera socket visible in Docker."; fi

  if docker_cuda="$(docker exec "$CONTAINER" bash /opt/jetson-codex/hardware-check.sh --cuda 2>&1)"; then
    say "Container $docker_cuda"
    if [[ "$host_cuda" == CUDA* && "$host_cuda" != "$docker_cuda" ]]; then
      fail "CUDA GPU device count differs between host and container."
    fi
  else
    fail "CUDA driver access failed inside Docker: $docker_cuda"
  fi

  say "Running actual H.264 decode through the Jetson hardware decoder."
  docker exec "$CONTAINER" bash /opt/jetson-codex/hardware-check.sh --video \
    || fail "NVDEC test failed: check NVIDIA runtime, GStreamer plugins and driver/device compatibility."

  say "Running a real DeepStream NVIDIA NVMM pipeline and checking inference plugins."
  docker exec "$CONTAINER" bash /opt/jetson-codex/hardware-check.sh --deepstream \
    || fail "DeepStream pipeline failed: NVIDIA GStreamer plugins, device nodes or runtime libraries may be unavailable."

  # Building a TensorRT engine can take time on the 7W Orin. Run on each
  # newly built image; on unchanged reruns, retain the fast SDK checks.
  if (( BUILD )); then
    say "Building a small TensorRT 10 engine and executing GPU inference."
    docker exec "$CONTAINER" bash /opt/jetson-codex/hardware-check.sh --tensorrt \
      || fail "TensorRT GPU inference failed: compiler, TensorRT SDK or CUDA runtime is not usable."
  fi
}

if docker container inspect "$CONTAINER" >/dev/null 2>&1; then
  current_image="$(docker inspect --format '{{.Config.Image}}' "$CONTAINER")"
  [[ "$current_image" == "$IMAGE" ]] || fail "A container named '$CONTAINER' already exists using '$current_image'. Not replacing an unrelated container."
  if [[ "$MODE" == "hardware" ]]; then
    if (( BUILD )) || ! docker ps --format '{{.Names}}' | grep -Fxq "$CONTAINER" || ! docker exec "$CONTAINER" test -d /workspace/projects || ! explicit_devices_current; then
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

# Verify NVIDIA devices and execute a real NVDEC decode on every rerun.
hardware_health

# Prune BuildKit cache only AFTER successful container startup AND NVIDIA
# runtime acceptance tests. A failing GPU test retains expensive build cache
# so an iterative fix does not require downloading/rebuilding from scratch.
if (( BUILD )); then
  say "New image passed hardware checks; reclaiming unused Docker build cache."
  if docker buildx prune --all --force; then
    say "Docker build cache cleanup completed."
  else
    say "WARNING: Build cache cleanup failed; running container is unaffected."
  fi
  # Old untagged revisions of jetson-codex would otherwise occupy many GiB.
  # Dangling-image prune never deletes the active image or named volumes.
  docker image prune --force ||
    say "WARNING: Dangling image cleanup failed; running container is unaffected."
  docker system df || true
fi

image_bytes="$(docker image inspect --format '{{.Size}}' "$IMAGE" 2>/dev/null || true)"
if [[ "$image_bytes" =~ ^[0-9]+$ ]]; then
  say "Built image (uncompressed filesystem layers): $(awk -v n="$image_bytes" 'BEGIN { printf "%.2f GiB", n/1073741824 }')"
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

# Offer the provider menu once. Credentials and SSH keys persist in named volumes.
if [[ -r /dev/tty && -w /dev/tty ]] && ! docker exec "$CONTAINER" test -f /root/.ssh/.jetson-providers-offered; then
  printf '\n%s\n' 'Codex supports GitHub, GitHub Enterprise, GitLab, Bitbucket and Azure DevOps.' >/dev/tty
  printf '%s' 'Link additional Git providers now? [y/N] ' >/dev/tty
  IFS= read -r provider_answer </dev/tty || provider_answer=n
  if [[ "$provider_answer" =~ ^[Yy]$ ]]; then
    docker exec -it "$CONTAINER" codex-connect </dev/tty >/dev/tty 2>&1 \
      || say "Git provider setup was interrupted; run codex-connect later."
  fi
  docker exec "$CONTAINER" touch /root/.ssh/.jetson-providers-offered \
    || say "Provider onboarding marker not saved; the menu may appear again."
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
  && docker exec "$CONTAINER" glab --version >/dev/null 2>&1 \
  && docker exec "$CONTAINER" az devops --help >/dev/null 2>&1 \
  && docker exec "$CONTAINER" codex-connect --status >/dev/null 2>&1 \
  && docker info --format '{{json .Runtimes}}' | grep -q '"nvidia"'; then
  say "Health OK: Codex, full trust, NVIDIA runtime, GitLab, Azure DevOps and Git connection tools."
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

Link or inspect Git providers any time:
  docker exec -it jetson-codex codex-connect

Saved credentials and full-trust settings survive container recreation and image rebuilds.
WARNING: Codex can execute commands without approval. This container uses host
networking and has access to mapped hardware and your mounted workspace.
DONE
