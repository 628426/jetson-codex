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
if ! command -v rclone >/dev/null 2>&1 || ! command -v fusermount3 >/dev/null 2>&1; then
  say "Installing rclone and FUSE3 using Ubuntu APT."
  sudo apt-get update
  sudo apt-get install -y rclone fuse3
  command -v rclone >/dev/null 2>&1 || fail "rclone installation failed"
  command -v fusermount3 >/dev/null 2>&1 || fail "FUSE3 installation failed"
fi
if [[ -f "$ENV_FILE" && "${1:-}" != "--reconfigure" ]]; then
  say "Existing storage configuration found. Use --reconfigure to change it."
  exit 0
fi
[[ -r /dev/tty && -w /dev/tty ]] || fail "Interactive SSH terminal required to link cloud storage."
if [[ "${RCLONE_SSH_TUNNEL:-0}" == "1" ]]; then
  cat >/dev/tty <<'GUIDE'

========================================================
  CLOUD STORAGE: ONE-CLICK WINDOWS BROWSER LOGIN
========================================================
  SSH port forwarding is enabled.

  1. Follow the rclone prompts to select OneDrive or Google Drive.
  2. The installer answers Y to automatic browser login.
  3. Open the http://127.0.0.1:53682/... URL on your Windows PC.
  4. Approve the Microsoft/Google access request.

  The callback travels back to the Jetson over your SSH connection.
  No Windows rclone, token JSON or second terminal needed.
========================================================

GUIDE
else
  cat >/dev/tty <<'GUIDE'

========================================================
  CLOUD STORAGE: HEADLESS JETSON
========================================================
  This SSH connection has no OAuth port forwarding.
  To avoid copying tokens, restart using the PowerShell
  command printed by install.sh when you select cloud setup.
========================================================

GUIDE
fi

remote=""
mapfile -t remotes < <(rclone listremotes | sed 's/:$//')
if ((${#remotes[@]} > 0)); then
  printf 'Existing rclone remotes:\n' >/dev/tty
  printf '  %s\n' "${remotes[@]}" >/dev/tty
  printf 'Enter an existing remote to use, or Enter to link a new one: ' >/dev/tty
  IFS= read -r chosen </dev/tty
  if [[ -n "$chosen" ]]; then
    for candidate in "${remotes[@]}"; do
      if [[ "$candidate" == "$chosen" ]]; then remote="$chosen"; break; fi
    done
    [[ -n "$remote" ]] || fail "No such rclone remote: $chosen"
  fi
fi

if [[ -z "$remote" ]]; then
  if ! command -v expect >/dev/null 2>&1; then
    say "Installing terminal automation for guaranteed headless OAuth."
    sudo apt-get update
    sudo apt-get install -y --no-install-recommends expect
  fi
  say "Starting rclone's normal provider setup."
  if [[ "${RCLONE_SSH_TUNNEL:-0}" == "1" ]]; then
    export RCLONE_OAUTH_ANSWER=y
    say "SSH OAuth forwarding is active. Open the printed localhost:53682 link in your PC browser."
    say "Microsoft/Google return to localhost on the PC; SSH forwards that callback to the Jetson."
  else
    export RCLONE_OAUTH_ANSWER=n
    say "No SSH OAuth tunnel requested; using the normal headless token handoff."
    say "For one-click browser login, reconnect using the Windows SSH -L command in README.md."
  fi
  # Keep the interactive wizard (including OneDrive drive selection).
  # Answer the browser-location question based on whether the client
  # deliberately opened an SSH forward. The OAuth redirect URI is fixed
  # at localhost:53682 by the provider registration, NOT the Jetson LAN IP.
  expect -c '
    set timeout -1
    set answer $env(RCLONE_OAUTH_ANSWER)
    spawn -noecho rclone config
    interact -o -re {Use auto config\?|Use web browser to automatically authenticate rclone with remote\?} {
      send -- "$answer\r"
    }
    set result [wait]
    exit [lindex $result 3]
  ' </dev/tty >/dev/tty 2>&1 \
    || fail "Rclone cloud setup did not finish. Re-run installer to retry."

  mapfile -t connected_remotes < <(rclone listremotes | sed 's/:$//')
  new_remotes=()
  for candidate in "${connected_remotes[@]}"; do
    found=0
    for previous in "${remotes[@]}"; do
      if [[ "$candidate" == "$previous" ]]; then found=1; break; fi
    done
    (( found )) || new_remotes+=("$candidate")
  done
  if ((${#new_remotes[@]} == 1)); then
    remote="${new_remotes[0]}"
    say "New cloud remote detected: $remote"
  else
    printf 'Available rclone remotes:\n' >/dev/tty
    printf '  %s\n' "${connected_remotes[@]}" >/dev/tty
    printf 'Remote name to mount: ' >/dev/tty
    IFS= read -r remote </dev/tty
    valid=0
    for candidate in "${connected_remotes[@]}"; do
      [[ "$candidate" == "$remote" ]] && valid=1
    done
    (( valid )) || fail "No such rclone remote: $remote"
  fi
fi

say "Checking that $remote is accessible."
timeout 45 rclone lsf "$remote:" --max-depth 1 >/dev/null \
  || fail "Remote '$remote' could not be listed. Check its OAuth credentials and rerun."

printf 'Cloud project root folder [Codex]: ' >/dev/tty
IFS= read -r folder </dev/tty
folder="${folder:-Codex}"
[[ "$folder" != *'..'* && "$folder" != /* && "$folder" != *:* ]] || fail "Invalid cloud root folder."
source_path="$remote:$folder"

if ! timeout 45 rclone lsf "$source_path" --max-depth 1 >/dev/null 2>&1; then
  say "Creating cloud project folder: $source_path"
  rclone mkdir "$source_path" || fail "Could not create cloud project folder."
fi
timeout 45 rclone lsf "$source_path" --max-depth 1 >/dev/null \
  || fail "Cloud project folder is not accessible."
printf 'RCLONE_REMOTE=%q\nRCLONE_SOURCE=%q\nRCLONE_MOUNT=%q\nRCLONE_CACHE=%q\n' "$remote" "$source_path" "$MOUNT" "$CACHE" > "$ENV_FILE"
chmod 600 "$ENV_FILE"
say "Saved configuration to $ENV_FILE"
install_mount "${1:-}"
