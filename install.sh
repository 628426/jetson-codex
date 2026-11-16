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

DISK_MONITOR_PID=""
INSTALL_TMP_DIR=""
stop_disk_monitor() {
  if [[ -n "$DISK_MONITOR_PID" ]]; then
    kill "$DISK_MONITOR_PID" 2>/dev/null || true
    wait "$DISK_MONITOR_PID" 2>/dev/null || true
    DISK_MONITOR_PID=""
  fi
}
cleanup_install() {
  stop_disk_monitor
  if [[ -n "$INSTALL_TMP_DIR" && -d "$INSTALL_TMP_DIR" ]]; then
    rm -rf -- "$INSTALL_TMP_DIR"
  fi
}
trap cleanup_install EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP


# Only one installer option: --uninstall. Handle it before JetPack,
# Docker, network and cloud health checks, including on incomplete installs.
if [[ "$#" -eq 1 && "$1" == "--uninstall" ]]; then
  [[ "$EUID" -ne 0 ]] || fail "Run uninstall as the installing user, not root."
  if [[ -f "$REPO_DIR/uninstall.sh" ]]; then
    bash "$REPO_DIR/uninstall.sh"
  else
    # A checkout may be absent or partially installed; the verified main
    # helper can still remove project-specific Docker/systemd resources.
    curl -fsSL https://raw.githubusercontent.com/628426/jetson-codex/main/uninstall.sh |
      bash || fail "Cannot run uninstall helper."
  fi
  exit 0
fi
(( $# == 0 )) || fail "Usage: install.sh [--uninstall]"
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
    IMAGE="jetson-codex:jp72-base"
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
  local_head="$(git -C "$REPO_DIR" rev-parse HEAD)"
  remote_head="$(git -C "$REPO_DIR" ls-remote origin refs/heads/main | awk '{print $1}')"
  [[ "$remote_head" =~ ^[0-9a-f]{40}$ ]] || fail "Cannot verify remote main HEAD; refusing an unverified update."
  if [[ "$local_head" == "$remote_head" ]]; then
    say "Repository already at origin/main; skipping git pull."
  else
    say "Repository update available; fast-forwarding $REPO_DIR."
    git -C "$REPO_DIR" pull --ff-only origin main
  fi
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
# R39.2's pre-1.19.1 CUDA CDI hook can crash on Orin's ELF compatibility
# note before PID 1 starts. Fix host toolkit once, using only existing NVIDIA
# APT sources, without altering JetPack drivers or the container image.
# A healthy toolkit is a no-op here, not an unconditional APT operation.
say "Verifying host NVIDIA CDI runtime can parse the Orin CUDA compat header."
bash ./check-nvidia-toolkit.sh ||
  fail "Host NVIDIA Container Toolkit needs repair before Docker can start. No container or cloud data deleted."
# Check each independent security-update prerequisite before changing it.
if dpkg-query -W -f='\x24{Status}' unattended-upgrades 2>/dev/null | grep -Fxq 'install ok installed'; then
  say "Ubuntu unattended-upgrades package already installed."
else
  say "Installing missing unattended-upgrades package."
  sudo apt-get update
  sudo apt-get install -y unattended-upgrades
fi
upgrade_conf=/etc/apt/apt.conf.d/20auto-upgrades
if [[ -f "$upgrade_conf" ]] \
  && grep -Eq '^[[:space:]]*APT::Periodic::Update-Package-Lists[[:space:]]+"1";' "$upgrade_conf" \
  && grep -Eq '^[[:space:]]*APT::Periodic::Unattended-Upgrade[[:space:]]+"1";' "$upgrade_conf"; then
  say "Ubuntu unattended security update policy already configured."
else
  say "Configuring Ubuntu unattended security update policy."
  # Keep a prior configuration as a backup rather than deleting custom values.
  [[ ! -f "$upgrade_conf" ]] || sudo cp -n "$upgrade_conf" "$upgrade_conf.jetson-codex.bak"
  printf '%s\n' 'APT::Periodic::Update-Package-Lists "1";' 'APT::Periodic::Unattended-Upgrade "1";' 'APT::Periodic::AutocleanInterval "7";' | sudo tee "$upgrade_conf" >/dev/null
fi
for timer in apt-daily.timer apt-daily-upgrade.timer; do
  if systemctl is-enabled --quiet "$timer"; then
    say "$timer already enabled."
  else
    sudo systemctl enable "$timer"
  fi
  if systemctl is-active --quiet "$timer"; then
    say "$timer already active."
  else
    sudo systemctl start "$timer"
  fi
done
# Reclaim host APT package downloads only when cache contains .deb files.
if sudo find /var/cache/apt/archives -maxdepth 1 -type f -name '*.deb' -print -quit | grep -q .; then
  say "Cleaning downloaded APT package archives."
  sudo apt-get clean || say "WARNING: Host APT cache cleanup failed."
else
  say "APT package archives already clean."
fi
[[ -f "$DOCKERFILE" ]] || fail "Selected Dockerfile missing: $DOCKERFILE"
INSTALL_TMP_DIR="$(mktemp -d -t jetson-codex-install.XXXXXXXX)"
# Do not stat/mkdir the FUSE mount yet: a broken endpoint may reject mkdir
# before storage-health.sh gets a chance to offer interactive recovery.
[[ -d workspace ]] || mkdir workspace
[[ -d workspace/source ]] || mkdir workspace/source
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
# Peak-space architecture:
# 1. Build the minimal CUDA foundation (never the full SDK).
# 2. Start ONE persistent container, then reclaim BuildKit cache.
# 3. APT/DeepStream/Codex install into that container's writable layer.
# 4. NEVER docker commit/export or silently replace a provisioned container.
# Keep independent hashes: helper/provision changes must not rebuild CUDA base.
[[ -f "$DOCKERFILE" ]] || fail "Selected base Dockerfile missing."
[[ -f provision-container.sh ]] || fail "Post-up provisioning script missing."
export JETSON_CODEX_BUILD_HASH="$(sha256sum "$DOCKERFILE" | awk '{print $1}')"
PROVISION_HASH="$(sha256sum provision-container.sh | awk '{print $1}')"
PROVISIONED=0
# A one-time legacy migration deletes the previous full-image container's
# writable layer. This is NEVER automatic even if all named volumes are safe.
if docker container inspect "$CONTAINER" >/dev/null 2>&1; then
  current_image="$(docker inspect --format '{{.Config.Image}}' "$CONTAINER")"
  if [[ "$current_image" != "$IMAGE" ]]; then
    if [[ "$current_image" == jetson-codex:jp72-full && "${JETSON_CODEX_MIGRATE:-0}" == 1 ]]; then
      say "Explicit migration requested: replacing legacy full-image container."
      say "WARNING: unmounted data in its writable layer will be lost; named auth volumes and host mounts survive."
      docker rm -f "$CONTAINER" >/dev/null || fail "Cannot remove legacy container."
      docker image rm jetson-codex:jp72-full >/dev/null || say "Legacy image still referenced; leaving it alone."
    else
      fail "Existing $CONTAINER uses $current_image. To migrate from the legacy full image explicitly run JETSON_CODEX_MIGRATE=1 (this discards unmounted container changes). No data changed."
    fi
  fi
fi

if docker image inspect "$IMAGE" >/dev/null 2>&1; then
  installed_hash="$(docker image inspect --format '{{index .Config.Labels "org.jetson-codex.build-hash"}}' "$IMAGE" 2>/dev/null || true)"
  if [[ "$installed_hash" != "$JETSON_CODEX_BUILD_HASH" ]]; then
    if docker container inspect "$CONTAINER" >/dev/null 2>&1; then
      if [[ "${JETSON_CODEX_MIGRATE:-0}" != 1 ]]; then
        fail "Base image changed, but the existing container holds post-installed packages. Refusing to recreate it. Explicit JETSON_CODEX_MIGRATE=1 required."
      fi
      say "Explicit base replacement requested. Discarding container writable layer; named volumes survive."
      docker rm -f "$CONTAINER" >/dev/null || fail "Cannot remove old base container."
    fi
    docker image rm "$IMAGE" >/dev/null || fail "Cannot replace incompatible base image."
    BUILD=1
  else
    say "Minimal CUDA base image is current; skipping Docker build."
  fi
else
  BUILD=1
fi

if (( BUILD )); then
  say "Building minimal CUDA base (no APT or SDK provisioning in Dockerfile)."
  bash ./disk-space.sh pre || say "WARNING: Pre-base cache cleanup failed."
  bash ./disk-space.sh monitor "$BASHPID" &
  DISK_MONITOR_PID=$!
  if ! docker compose --progress plain build; then
    stop_disk_monitor
    fail "Minimal CUDA base build failed. No container was automatically removed."
  fi
  stop_disk_monitor
fi
docker image inspect "$IMAGE" >/dev/null 2>&1 || fail "CUDA base image unavailable."
# Critical for peak space: dispose of reclaimable build cache BEFORE starting
# the large post-up APT process, not after it has accumulated its downloads.
if (( BUILD )) || ! docker container inspect "$CONTAINER" >/dev/null 2>&1; then
  say "Freeing BuildKit cache before post-start APT provisioning."
  bash ./disk-space.sh post || say "WARNING: BuildKit cache cleanup failed."
fi

# Cloud access can change while pulling the minimal base. Recheck the live
# FUSE mount before Docker startup, but don't mutate credentials.
if [[ -f "$STORAGE_ENV" ]]; then
  say "Rechecking cloud storage before starting the persistent container."
  bash ./storage-health.sh || fail "Cloud unavailable; container left untouched."
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
  hostlist="$INSTALL_TMP_DIR/host-devices.txt"
  dockerlist="$INSTALL_TMP_DIR/container-devices.txt"
  missingfile="$INSTALL_TMP_DIR/missing-devices.txt"
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
  if (( PROVISIONED )); then
    say "Building a small TensorRT 10 engine and executing GPU inference."
    docker exec "$CONTAINER" bash /opt/jetson-codex/hardware-check.sh --tensorrt \
      || fail "TensorRT GPU inference failed: compiler, TensorRT SDK or CUDA runtime is not usable."
  fi
}

# Never recycle the post-provisioned upperdir to refresh hardware devices.
# Device mappings are fixed at creation; fail safely if a new device appears.
if docker container inspect "$CONTAINER" >/dev/null 2>&1; then
  if ! explicit_devices_current; then
    fail "Host character devices changed since container creation. Refusing to recreate and lose installed SDK; arrange an explicit migration."
  fi
fi
say "Ensuring persistent hardware container is running without replacing it."
bash ./run-hardware.sh || fail "Could not start/reuse the persistent container."
docker ps --filter "name=^/$CONTAINER$" --format '{{.Names}}' | grep -Fxq "$CONTAINER" \
  || fail "$CONTAINER is not running; inspect docker logs."

# Install the heavy SDK only AFTER the container is running.
# The per-container marker and command probes make normal reruns a no-op.
current_hash="$(docker exec "$CONTAINER" cat /var/lib/jetson-codex/provision.sha256 2>/dev/null || true)"
if [[ "$current_hash" == "$PROVISION_HASH" ]] \
  && docker exec "$CONTAINER" test -x /opt/nvidia/deepstream/deepstream-9.1/bin/deepstream-app \
  && docker exec "$CONTAINER" bash -c 'command -v codex && command -v gh && command -v glab && command -v az' >/dev/null 2>&1; then
  say "Post-up SDK provision marker and tools match; skipping APT/DeepStream installation."
else
  PROVISIONED=1
  say "Running one-off post-up APT/SDK provision inside existing container upperdir."
  say "No docker commit/export and no duplicate full image will be created."
  docker exec -e "JETSON_CODEX_PROVISION_HASH=$PROVISION_HASH" "$CONTAINER" \
    bash /opt/jetson-codex/provision-container.sh \
    || fail "Post-up provision failed. Existing container retained, including partial APT state. Rerun to resume."
  [[ "$(docker exec "$CONTAINER" cat /var/lib/jetson-codex/provision.sha256 2>/dev/null || true)" == "$PROVISION_HASH" ]] \
    || fail "Post-up provision marker mismatch."
  say "Post-up provisioning complete. Container writable layer retained."
fi

# Verify NVIDIA devices and execute a real NVDEC decode on every rerun.
hardware_health

# Reclaim all eligible cache as soon as hardware acceptance completes.
# A failed install also receives EXIT-trap scratch cleanup, and the monitor
# prunes during the build if Docker storage drops below its free-space target.
if (( PROVISIONED )); then
  say "Post-up image provision complete. No image export or commit performed."
fi

image_bytes="$(docker image inspect --format '{{.Size}}' "$IMAGE" 2>/dev/null || true)"
if [[ "$image_bytes" =~ ^[0-9]+$ ]]; then
  say "Minimal base image (uncompressed filesystem layers): $(awk -v n="$image_bytes" 'BEGIN { printf "%.2f GiB", n/1073741824 }')"
fi

# User-requested full trust: Codex may execute commands without approval prompts.
# Persist in the existing Codex auth volume; keep the container boundary.
if docker exec "$CONTAINER" python3 -c 'import pathlib,tomllib; p=pathlib.Path.home()/".codex/config.toml"; c=tomllib.loads(p.read_text()); assert c.get("approval_policy")=="never" and c.get("sandbox_mode")=="danger-full-access"' >/dev/null 2>&1; then
  say "Codex full-trust settings already correct; skipping configuration."
else
  say "Configuring Codex full trust (no approvals, unrestricted container filesystem)"
  docker exec "$CONTAINER" python3 /opt/jetson-codex/configure-full-trust.py \
    || fail "Could not configure Codex full-trust defaults."
fi

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

# After ChatGPT login, enable Codex's native Remote Control daemon and offer
# a short-lived mobile pairing code once. Not an SSH wrapper or host Codex install.
# The helper records that a CODE WAS OFFERED, never claims the phone is paired.
say "Checking Codex Remote Control and mobile pairing."
bash ./codex-remote.sh auto || say "WARNING: Remote Control unavailable; continue with SDK verification."

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

[jetson-codex] Persistent, post-provisioned container is running.
Do not run docker rm or docker compose down: those remove installed SDK files
stored in its writable layer. docker stop/start preserves the installation.

Enter it:
  docker exec -it jetson-codex bash -l

Codex device login (if still required):
  docker exec -it jetson-codex codex login --device-auth
  https://auth.openai.com/codex/device

ChatGPT mobile pairing (use after logging into Codex):
  bash ~/jetson-codex/codex-remote.sh pair
  # Enter the short-lived code in ChatGPT mobile Codex/Remote.
  # A new code is only generated when requested after the first offer.

GitHub CLI login (separate, once):
  docker exec -it jetson-codex gh auth login --hostname github.com --git-protocol https --web
  https://github.com/login/device
  docker exec jetson-codex gh auth setup-git

Run Codex:
  docker exec -it jetson-codex codex

Link or inspect Git providers any time:
  docker exec -it jetson-codex codex-connect

Saved credentials persist in named volumes. Installed SDK tools are in the
container writable layer and DO NOT survive container deletion/recreation.
WARNING: Codex can execute commands without approval. This container uses host
networking and has access to mapped hardware and your mounted workspace.
DONE
