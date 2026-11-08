#!/usr/bin/env bash
# Interactive, non-destructive rclone health and repair gate.
# Run before starting or rebuilding the Docker image, never in the container.
set -Eeuo pipefail

say() { printf '[storage-check] %s\n' "$*"; }
fail() { printf '[storage-check] ERROR: %s\n' "$*" >&2; exit 1; }
ENV_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/jetson-codex/storage.env"
SERVICE=jetson-codex-cloud.service
[[ -f "$ENV_FILE" ]] || fail "No saved cloud configuration. Use configure-storage.sh to create it."
[[ -r /dev/tty && -w /dev/tty ]] && INTERACTIVE=1 || INTERACTIVE=0

# source only our own chmod-600 generated storage.env, not cloud content.
load_storage() {
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  [[ -n "${RCLONE_REMOTE:-}" && -n "${RCLONE_SOURCE:-}" &&
     -n "${RCLONE_MOUNT:-}" ]] || fail "Incomplete storage.env. Reconfigure storage."
  # Never allow unmounting an arbitrary location if the local env is corrupt.
  [[ "$RCLONE_MOUNT" == "$HOME/jetson-codex-cloud" ]] ||
    fail "Unexpected cloud mount path. Refusing to modify: $RCLONE_MOUNT"
}

show_tunnel() {
  local server_ip=""
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    read -r _client _port server_ip _server_port <<< "$SSH_CONNECTION"
  fi
  [[ "$server_ip" == *.* ]] ||
    server_ip="$(hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\./) {print $i; exit}}')"
  server_ip="${server_ip:-$(hostname -s)}"
  say "PAUSED before Docker build. Cloud OAuth needs the SSH browser tunnel."
  printf '\nRun this in Windows PowerShell:\n' >&2
  printf "ssh -tt -o ExitOnForwardFailure=yes -L 53682:127.0.0.1:53682 %s@%s 'export RCLONE_SSH_TUNNEL=1; curl -fsSL https://raw.githubusercontent.com/628426/jetson-codex/main/install.sh | bash'\n\n" "$USER" "$server_ip" >&2
}

# Cloud remote authentication and the local FUSE mount are separate checks.
# A green systemd service alone is NOT evidence that the mount works.
storage_healthy() {
  load_storage
  command -v rclone >/dev/null || { say "rclone is missing."; return 1; }
  command -v timeout >/dev/null || { say "timeout is missing."; return 1; }
  say "Testing remote: $RCLONE_SOURCE"
  if ! timeout 45 rclone lsf "$RCLONE_SOURCE" --max-depth 1 >/dev/null; then
    say "Remote listing failed (OAuth, network or access permissions)."
    return 1
  fi
  if ! systemctl --user is-active --quiet "$SERVICE"; then
    say "Cloud mount service is not active."
    return 1
  fi
  if ! mountpoint -q "$RCLONE_MOUNT"; then
    say "Cloud folder is not actually mounted: $RCLONE_MOUNT"
    return 1
  fi
  # This traverses FUSE rather than just stat'ing the underlying mountpoint.
  if ! timeout 20 ls -A "$RCLONE_MOUNT" >/dev/null; then
    say "Cloud mount cannot list files (possibly a stale FUSE endpoint)."
    return 1
  fi
  say "PASS: remote OAuth/access, service, FUSE mount and directory listing."
}

# Explicitly chosen by the user. Never rm -rf the FUSE mount or its cache.
repair_mount() {
  load_storage
  say "Stopping the mount service. Check that no rclone uploads are pending."
  systemctl --user stop "$SERVICE" || true
  if mountpoint -q "$RCLONE_MOUNT"; then
    # Avoid lazy-unmounting and losing pending uploads. If busy, stop safely.
    fusermount3 -u "$RCLONE_MOUNT" ||
      fail "Mount is busy. Close any shell/container using it, then rerun installer. Nothing deleted."
  fi
  bash ./configure-storage.sh --mount ||
    fail "Unable to start cloud mount. No Docker build was started."
}

reconnect_oauth() {
  load_storage
  if [[ "${RCLONE_SSH_TUNNEL:-0}" != 1 ]]; then
    show_tunnel
    return 2
  fi
  say "Renewing OAuth for existing remote $RCLONE_REMOTE (not deleting its files)."
  bash ./configure-storage.sh --reconnect ||
    fail "OAuth reconnection failed. No Docker build was started."
  # Restart only after the browser reconnect succeeds.
  repair_mount
}

reconfigure_storage() {
  if [[ "${RCLONE_SSH_TUNNEL:-0}" != 1 ]]; then
    show_tunnel
    return 2
  fi
  say "Reconfiguring OneDrive/Google Drive. Existing remote files will not be deleted."
  bash ./configure-storage.sh --reconfigure ||
    fail "Cloud reconfiguration failed. No Docker build was started."
}

# First try a non-invasive mount activation. If remote credentials are broken,
# the user gets a genuine interactive repair menu rather than silent fallback.
if ! storage_healthy; then
  say "Cloud is not healthy. Pausing before Docker."
  if (( ! INTERACTIVE )); then
    show_tunnel
    fail "Interactive terminal required to repair existing cloud storage."
  fi
  while :; do
    cat >/dev/tty <<'MENU'

Cloud storage failed verification. Docker build is PAUSED.
  1) Retry connection / restart FUSE mount
  2) Reconnect OAuth for the existing OneDrive/Google remote
  3) Reconfigure cloud provider, remote or project folder
  4) Abort (leave Docker and cloud data untouched)
MENU
    printf 'Choose [1-4]: ' >/dev/tty
    IFS= read -r choice </dev/tty || fail "Cloud recovery interrupted."
    case "$choice" in
      1) repair_mount || fail "Cloud mount repair failed." ;;
      2) reconnect_oauth || fail "Reconnect requires a working SSH OAuth tunnel." ;;
      3) reconfigure_storage || fail "Reconfiguration requires a working SSH OAuth tunnel." ;;
      4) fail "Cloud verification cancelled. Docker build NOT started." ;;
      *) say "Enter 1, 2, 3 or 4."; continue ;;
    esac
    if storage_healthy; then break; fi
    say "Cloud is still unavailable. Review the error and choose another repair."
  done
fi
