#!/usr/bin/env bash
# Configure a persistent, on-demand rclone cloud root on the Jetson host.
set -Eeuo pipefail
say(){ printf '[storage] %s\n' "$*"; }
fail(){ printf '[storage] ERROR: %s\n' "$*" >&2; exit 1; }
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/jetson-codex"
ENV_FILE="$CONFIG_DIR/storage.env"
MOUNT="$HOME/jetson-codex-cloud"
CACHE="$HOME/.cache/jetson-codex/rclone"
mkdir -p "$CONFIG_DIR" "$CACHE" "$MOUNT"
chmod 700 "$CONFIG_DIR" "$CACHE"
if ! command -v rclone >/dev/null 2>&1; then
  say "rclone missing. Install with: sudo apt install rclone fuse3"
  exit 2
fi
if [[ -f "$ENV_FILE" && "${1:-}" != "--reconfigure" ]]; then
  say "Existing storage configuration found. Use --reconfigure to change it."
  exit 0
fi
[[ -r /dev/tty && -w /dev/tty ]] || fail "Interactive terminal required for initial OAuth setup."
say "Configure OneDrive or Google Drive using rclone's interactive wizard."
say "For a headless Jetson, choose browser-less auth and complete OAuth on your PC."
rclone config </dev/tty >/dev/tty 2>&1
mapfile -t remotes < <(rclone listremotes | sed 's/:$//')
(("${#remotes[@]}" > 0)) || fail "No rclone remotes configured."
printf 'Available remotes:\n' >/dev/tty
printf '  %s\n' "${remotes[@]}" >/dev/tty
printf 'Remote name: ' >/dev/tty
IFS= read -r remote </dev/tty
[[ " ${remotes[*]} " == *" $remote "* ]] || fail "Unknown remote"
printf 'Cloud root folder (e.g. Codex, blank for drive root): ' >/dev/tty
IFS= read -r folder </dev/tty
[[ "$folder" != *'..'* && "$folder" != /* ]] || fail "Invalid cloud root"
source_path="$remote:"
[[ -z "$folder" ]] || source_path+="$folder"
# Validate access without uploading/deleting any files.
rclone lsf "$source_path" --max-depth 1 >/dev/null || fail "Cannot list $source_path. Create the cloud folder first."
printf 'RCLONE_REMOTE=%q\nRCLONE_SOURCE=%q\nRCLONE_MOUNT=%q\nRCLONE_CACHE=%q\n' "$remote" "$source_path" "$MOUNT" "$CACHE" > "$ENV_FILE"
chmod 600 "$ENV_FILE"
say "Saved configuration to $ENV_FILE"
say "Mount on demand with: bash configure-storage.sh --mount"
