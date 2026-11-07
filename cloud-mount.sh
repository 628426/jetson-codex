#!/usr/bin/env bash
# systemd user service entrypoint. Handles paths with spaces safely.
set -Eeuo pipefail
config="${XDG_CONFIG_HOME:-$HOME/.config}/jetson-codex/storage.env"
[[ -f "$config" ]] || { echo "Cloud storage is not configured" >&2; exit 1; }
# shellcheck disable=SC1090
source "$config"
exec rclone mount "$RCLONE_SOURCE" "$RCLONE_MOUNT" \
  --vfs-cache-mode full \
  --vfs-cache-max-size 2G \
  --vfs-cache-max-age 1h \
  --vfs-write-back 30s \
  --cache-dir "$RCLONE_CACHE" \
  --dir-cache-time 5m
