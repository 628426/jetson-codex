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
# Run as a user systemd service, so mounts survive reboots without sudo.
install_mount() {
  [[ -f "$ENV_FILE" ]] || fail "Run configure-storage.sh first."
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  mkdir -p "$RCLONE_MOUNT" "$RCLONE_CACHE" "$HOME/.config/systemd/user"
  local unit="$HOME/.config/systemd/user/jetson-codex-cloud.service"
  cat > "$unit" <<EOF
[Unit]
Description=Jetson Codex cloud project filesystem
Wants=network-online.target
After=network-online.target

[Service]
Type=notify
Environment=HOME=$HOME
ExecStart=/bin/bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cloud-mount.sh"
ExecStop=/usr/bin/fusermount3 -uz "$RCLONE_MOUNT"
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable jetson-codex-cloud.service
  if [[ "${1:-}" == "--reconfigure" ]]; then
    say "Restarting mount after configuration change; ensure no pending uploads."
    systemctl --user restart jetson-codex-cloud.service
  elif ! systemctl --user is-active --quiet jetson-codex-cloud.service; then
    systemctl --user start jetson-codex-cloud.service
  else
    say "Existing cloud mount is active; leaving it untouched."
  fi
  say "Cloud mount service enabled: $RCLONE_MOUNT"
  if ! loginctl show-user "$USER" -p Linger | grep -q 'Linger=yes'; then
    say "For mounting after reboot without login, run: sudo loginctl enable-linger $USER"
  fi
}
if [[ "${1:-}" == "--mount" ]]; then install_mount; exit 0; fi
if ! command -v rclone >/dev/null 2>&1; then
  say "rclone missing. Install with: sudo apt install rclone fuse3"
  exit 2
fi
if [[ -f "$ENV_FILE" && "${1:-}" != "--reconfigure" ]]; then
  say "Existing storage configuration found. Use --reconfigure to change it."
  exit 0
fi
[[ -r /dev/tty && -w /dev/tty ]] || fail "Interactive terminal required for initial OAuth setup."
cat >/dev/tty <<'GUIDE'

========================================================
  CLOUD STORAGE LINKING (headless Jetson)
========================================================
  1. Choose 'n' to create a new rclone remote.
  2. Name it 'onedrive' or 'gdrive'.
  3. Select Microsoft OneDrive or Google Drive.
  4. Leave client ID and secret blank for defaults.
  5. When asked to open a browser automatically, choose N.

  On your Windows PC:
    Install rclone: https://rclone.org/downloads/
    Open PowerShell and run the rclone authorize command
    EXACTLY as printed by the Jetson wizard.
    Complete browser sign-in on the PC.
    Paste the resulting token JSON into the SSH terminal.

  Return to SSH, complete drive selection and choose 'q'.

  OneDrive: https://rclone.org/onedrive/
  Google Drive: https://rclone.org/drive/
========================================================

GUIDE
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
install_mount
