#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$(realpath "$0")")"
mkdir -p workspace
args=(run --rm -it --name jetson-codex --runtime=nvidia --init
      --shm-size=1g -v "${PWD}/workspace:/workspace" -v jetson-codex-auth:/root/.codex
      -w /workspace -e NVIDIA_VISIBLE_DEVICES=all -e NVIDIA_DRIVER_CAPABILITIES=all)
# Only grant actual device nodes. No --privileged, --pid=host or Docker socket.
shopt -s nullglob
for dev in /dev/video[0-9]* /dev/i2c-[0-9]* /dev/gpiochip[0-9]* /dev/ttyUSB[0-9]* /dev/ttyACM[0-9]*; do
  if [[ -c "$dev" ]]; then args+=(--device "$dev:$dev"); fi
done
# The Jetson Argus camera server uses this Unix socket if CSI cameras are attached.
if [[ -S /tmp/argus_socket ]]; then
  args+=(-v /tmp/argus_socket:/tmp/argus_socket)
fi
args+=(jetson-codex:jp62-full bash -l)
exec docker "${args[@]}"
