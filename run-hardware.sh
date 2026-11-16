#!/usr/bin/env bash
# Launch once; installed APT/SDK state lives in THIS container's writable layer.
# Never automatically remove/recreate it: that would discard provisioning.
set -Eeuo pipefail
cd "$(dirname "$(realpath "$0")")"
image="${JETSON_CODEX_IMAGE:-jetson-codex:jp72-base}"
container=jetson-codex
mkdir -p workspace workspace/source
cloud_mount="$HOME/jetson-codex-cloud"
if [[ -f "${XDG_CONFIG_HOME:-$HOME/.config}/jetson-codex/storage.env" ]]; then
  mountpoint -q "$cloud_mount" || {
    echo "Configured rclone mount is not active: $cloud_mount" >&2; exit 1;
  }
else
  [[ -d "$cloud_mount" ]] || mkdir -p "$cloud_mount"
fi

if docker container inspect "$container" >/dev/null 2>&1; then
  current_image="$(docker inspect --format '{{.Config.Image}}' "$container")"
  [[ "$current_image" == "$image" ]] || {
    echo "Container $container uses $current_image, expected $image; refusing to discard its writable layer." >&2
    exit 1
  }
  # Require the source bind added by this architecture; never assume a
  # legacy container has it and then accidentally overwrite its state.
  if ! docker inspect --format '{{range .Mounts}}{{println .Destination}}{{end}}' "$container" | grep -Fxq /opt/jetson-codex; then
    echo "Existing container lacks /opt/jetson-codex bind mount; manual migration required." >&2
    exit 1
  fi
  if [[ "$(docker inspect --format '{{.State.Running}}' "$container")" == true ]]; then
    echo "Container '$container' already running; preserving installed filesystem."
  else
    echo "Restarting EXISTING $container container; preserving installed packages."
    docker start "$container" >/dev/null
  fi
  exit 0
fi

args=(run -d --name "$container" --restart unless-stopped
      --runtime=nvidia --network=host --init --shm-size=1g
      --mount "type=bind,source=$PWD,target=/opt/jetson-codex,readonly"
      --mount "type=bind,source=$PWD/workspace,target=/workspace"
      --mount "type=bind,source=$PWD/workspace/source,target=/workspace/source"
      --mount "type=bind,source=$cloud_mount,target=/workspace/projects,bind-propagation=rslave"
      -v jetson-codex-auth:/root/.codex
      -v jetson-github-auth:/root/.config/gh
      -v jetson-git-config:/root/.config/git
      -v jetson-codex-git-ssh:/root/.ssh
      -v jetson-codex-gitlab-auth:/root/.config/glab-cli
      -v jetson-codex-azure-auth:/root/.azure
      -w /workspace
      -e NVIDIA_VISIBLE_DEVICES=all
      -e NVIDIA_DRIVER_CAPABILITIES=all
      -e GIT_CONFIG_GLOBAL=/root/.config/git/config)
mapfile -t hardware_nodes < <(bash ./hardware-check.sh --devices)
for dev in "${hardware_nodes[@]}"; do
  [[ ! -c "$dev" ]] || args+=(--device "$dev:$dev")
done
echo "[jetson-codex] Mapping ${#hardware_nodes[@]} available host character devices."
if [[ -S /tmp/argus_socket ]]; then
  args+=(--mount "type=bind,source=/tmp/argus_socket,target=/tmp/argus_socket")
fi
args+=("$image" sleep infinity)
# docker run may leave a Failed/Created container. Refuse to remove it
# automatically: the installer must not guess what needs preserving.
docker "${args[@]}" || {
  echo "Container startup failed. Inspect docker ps -a; no cleanup was attempted." >&2
  exit 1
}
if [[ -f "${XDG_CONFIG_HOME:-$HOME/.config}/jetson-codex/storage.env" ]]; then
  docker exec "$container" timeout 20 ls -A /workspace/projects >/dev/null || {
    echo "Container cannot read cloud project mount." >&2; exit 1;
  }
fi
echo "Container '$container' started; post-up provisioning can begin."
