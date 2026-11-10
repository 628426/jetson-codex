#!/usr/bin/env bash
# systemd user service entrypoint. Handles paths with spaces safely.
set -Eeuo pipefail
config="${XDG_CONFIG_HOME:-$HOME/.config}/jetson-codex/storage.env"
[[ -f "$config" ]] || { echo "Cloud storage is not configured" >&2; exit 1; }
# shellcheck disable=SC1090
source "$config"
# Docker's root-owned daemon must be able to traverse this user FUSE mount.
# --allow-root grants only the mounting user and root access; do not use the
# broader --allow-other mode. configure-storage.sh enables user_allow_other in
# /etc/fuse.conf, as required for non-root FUSE mounts using this option.
exec rclone mount "$RCLONE_SOURCE" "$RCLONE_MOUNT" \
  --allow-root \
  --vfs-cache-mode full \
  --vfs-cache-max-size 2G \
  --vfs-cache-max-age 1h \
  --vfs-write-back 30s \
  --cache-dir "$RCLONE_CACHE" \
  --dir-cache-time 5m
