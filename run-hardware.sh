#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$(realpath "$0")")"
mkdir -p workspace workspace/source "$HOME/jetson-codex-cloud"
if docker container inspect jetson-codex >/dev/null 2>&1; then
  echo "Container 'jetson-codex' already exists. If started with Compose, use 'docker compose down' first; if stopped, use 'docker start jetson-codex'." >&2
  exit 1
fi
args=(run -d --name jetson-codex --restart unless-stopped --runtime=nvidia --network=host --init
      --shm-size=1g -v "${PWD}/workspace:/workspace" -v jetson-codex-auth:/root/.codex
      -v jetson-github-auth:/root/.config/gh -v jetson-git-config:/root/.config/git
      -v jetson-codex-git-ssh:/root/.ssh
      -v jetson-codex-gitlab-auth:/root/.config/glab-cli
      -v jetson-codex-azure-auth:/root/.azure
      -v "$HOME/jetson-codex-cloud:/workspace/projects:rslave" \
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
docker "${args[@]}"
echo "Container 'jetson-codex' started. Enter with: docker exec -it jetson-codex bash -l"
