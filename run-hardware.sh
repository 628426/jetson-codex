#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$(realpath "$0")")"
# Never mkdir an existing FUSE mount; Docker's implicit -v mkdir is also
# unreliable when a user-owned FUSE mount is inaccessible to daemon root.
mkdir -p workspace workspace/source
cloud_mount="$HOME/jetson-codex-cloud"
if [[ -f "${XDG_CONFIG_HOME:-$HOME/.config}/jetson-codex/storage.env" ]]; then
  mountpoint -q "$cloud_mount" || {
    echo "Configured rclone mount is not active: $cloud_mount" >&2
    exit 1
  }
else
  mkdir -p "$cloud_mount"
fi

# Starting the helper twice is a no-op if our container is already healthy.
# A failed docker run may leave a Created container behind: clean only that
# exact image/name, never another container or any of the named volumes.
if docker container inspect jetson-codex >/dev/null 2>&1; then
  current_image="$(docker inspect --format '{{.Config.Image}}' jetson-codex)"
  [[ "$current_image" == 'jetson-codex:jp72-full' ]] || {
    echo "Refusing to replace unrelated container image $current_image" >&2
    exit 1
  }
  if [[ "$(docker inspect --format '{{.State.Running}}' jetson-codex)" == true ]]; then
    echo "Container 'jetson-codex' already running; nothing to do."
    exit 0
  fi
  echo "Removing stopped/failed jetson-codex container; auth volumes preserved."
  docker rm -f jetson-codex >/dev/null
fi
args=(run -d --name jetson-codex --restart unless-stopped --runtime=nvidia --network=host --init
      --shm-size=1g -v "${PWD}/workspace:/workspace" -v jetson-codex-auth:/root/.codex
      -v jetson-github-auth:/root/.config/gh -v jetson-git-config:/root/.config/git
      -v jetson-codex-git-ssh:/root/.ssh
      -v jetson-codex-gitlab-auth:/root/.config/glab-cli
      -v jetson-codex-azure-auth:/root/.azure
      --mount "type=bind,source=$cloud_mount,target=/workspace/projects,bind-propagation=rslave" \
      -v "${PWD}/workspace/source:/workspace/source" \
      -w /workspace -e NVIDIA_VISIBLE_DEVICES=all -e NVIDIA_DRIVER_CAPABILITIES=all
      -e GIT_CONFIG_GLOBAL=/root/.config/git/config)
# Grant only actual character devices reported by the common capability probe.
# This explicitly includes Jetson NVDEC/VIC/NVJPG nodes as well as camera
# and embedded I/O devices; NVIDIA runtime also contributes driver libraries.
# No --privileged, --pid=host, host filesystem, or Docker socket.
mapfile -t hardware_nodes < <(bash ./hardware-check.sh --devices)
for dev in "${hardware_nodes[@]}"; do
  if [[ -c "$dev" ]]; then args+=(--device "$dev:$dev"); fi
done
echo "[jetson-codex] Explicitly mapping ${#hardware_nodes[@]} available host hardware device nodes."
# The Jetson Argus camera server uses this Unix socket if CSI cameras are attached.
if [[ -S /tmp/argus_socket ]]; then
  args+=(-v /tmp/argus_socket:/tmp/argus_socket)
fi
args+=(jetson-codex:jp72-full sleep infinity)
if ! docker "${args[@]}"; then
  # A failed Docker bind mount can leave a container stuck in Created state.
  # Remove only that failed instance; do not touch any named auth volume.
  if docker container inspect jetson-codex >/dev/null 2>&1 &&
     [[ "$(docker inspect --format '{{.State.Running}}' jetson-codex)" != true ]] &&
     [[ "$(docker inspect --format '{{.Config.Image}}' jetson-codex)" == 'jetson-codex:jp72-full' ]]; then
    docker rm -f jetson-codex >/dev/null || true
  fi
  echo "Container startup failed. Check cloud bind access, then rerun the installer." >&2
  exit 1
fi
# Verify the mounted cloud is readable inside the actual Docker container.
if [[ -f "${XDG_CONFIG_HOME:-$HOME/.config}/jetson-codex/storage.env" ]]; then
  if ! docker exec jetson-codex timeout 20 ls -A /workspace/projects >/dev/null; then
    echo "Docker cannot list /workspace/projects. Check the FUSE --allow-root mount." >&2
    exit 1
  fi
fi
echo "Container 'jetson-codex' started. Enter with: docker exec -it jetson-codex bash -l"
