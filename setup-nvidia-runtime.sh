#!/usr/bin/env bash
# Idempotent Jetson host NVIDIA Docker runtime setup. Never changes user groups.
set -Eeuo pipefail
say(){ printf '[nvidia-runtime] %s\n' "$*"; }
fail(){ printf '[nvidia-runtime] ERROR: %s\n' "$*" >&2; exit 1; }
command -v docker >/dev/null || fail "Docker is not installed."
if docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q '"nvidia"'; then
  say "NVIDIA runtime already registered."
  exit 0
fi
if [[ $EUID -ne 0 ]]; then
  fail "Run with sudo: sudo bash setup-nvidia-runtime.sh"
fi
if ! command -v nvidia-ctk >/dev/null; then
  say "Installing NVIDIA Container Toolkit from configured APT repositories."
  apt-get update
  apt-get install -y nvidia-container-toolkit || fail "Package unavailable. Check Seeed/NVIDIA JetPack repositories; no third-party repository was added."
fi
command -v nvidia-ctk >/dev/null || fail "nvidia-ctk still missing."
say "Registering NVIDIA runtime in Docker configuration."
nvidia-ctk runtime configure --runtime=docker
systemctl restart docker
docker info --format '{{json .Runtimes}}' | grep -q '"nvidia"' || fail "NVIDIA runtime still missing after Docker restart."
say "NVIDIA Docker runtime registered successfully."
