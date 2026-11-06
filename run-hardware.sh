#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$(realpath "$0")")"
mkdir -p workspace
if docker container inspect jetson-codex >/dev/null 2>&1; then
  echo "Container 'jetson-codex' already exists. If started with Compose, use 'docker compose down' first; if stopped, use 'docker start jetson-codex'." >&2
  exit 1
fi
args=(run -d --name jetson-codex --restart unless-stopped --runtime=nvidia --network=host --init
      --shm-size=1g -v "${PWD}/workspace:/workspace" -v jetson-codex-auth:/root/.codex
      -v jetson-github-auth:/root/.config/gh -v jetson-git-config:/root/.config/git
      -w /workspace -e NVIDIA_VISIBLE_DEVICES=all -e NVIDIA_DRIVER_CAPABILITIES=all
      -e GIT_CONFIG_GLOBAL=/root/.config/git/config)
# Only grant actual device nodes. No --privileged, --pid=host or Docker socket.
shopt -s nullglob
for dev in /dev/video[0-9]* /dev/i2c-[0-9]* /dev/gpiochip[0-9]* /dev/ttyUSB[0-9]* /dev/ttyACM[0-9]*; do
  if [[ -c "$dev" ]]; then args+=(--device "$dev:$dev"); fi
done
# The Jetson Argus camera server uses this Unix socket if CSI cameras are attached.
if [[ -S /tmp/argus_socket ]]; then
  args+=(-v /tmp/argus_socket:/tmp/argus_socket)
fi
args+=(jetson-codex:jp62-full sleep infinity)
docker "${args[@]}"
echo "Container 'jetson-codex' started. Enter with: docker exec -it jetson-codex bash -l"
