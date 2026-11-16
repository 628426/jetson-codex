#!/usr/bin/env bash
# Destructive, explicitly confirmed cleanup for a complete Jetson Codex retest.
# Never delete cloud remote files or shared host software/configuration.
set -Eeuo pipefail

say() { printf '[jetson-codex-uninstall] %s\n' "$*"; }
fail() { say "ERROR: $*" >&2; exit 1; }
[[ "$EUID" -ne 0 ]] || fail 'Run as the original account, not sudo/root.'

REPO_DIR="$HOME/jetson-codex"
if [[ -v JETSON_CODEX_DIR && -n "$JETSON_CODEX_DIR" ]]; then
  REPO_DIR="$JETSON_CODEX_DIR"
fi
real_home="$(realpath -m -- "$HOME")"
real_repo="$(realpath -m -- "$REPO_DIR")"
[[ "$real_home" != / && "$real_repo" == "$real_home/"* &&
   "$(basename "$real_repo")" == jetson-codex && ! -L "$REPO_DIR" ]] ||
  fail "Unsafe checkout path: $REPO_DIR. Refusing recursive deletion."

if [[ -e "$REPO_DIR" ]]; then
  [[ -d "$REPO_DIR/.git" ]] ||
    fail "$REPO_DIR is not a Git checkout. Refusing to remove unrelated files."
  origin="$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null)" ||
    fail 'Cannot verify Git remote before deletion.'
  case "$origin" in
    https://github.com/628426/jetson-codex|https://github.com/628426/jetson-codex.git|git@github.com:628426/jetson-codex.git|ssh://git@github.com/628426/jetson-codex.git) ;;
    *) fail "Unexpected Git origin: $origin. Not removing checkout." ;;
  esac
fi

cat >&2 <<NOTICE

JETSON CODEX: COMPLETE LOCAL UNINSTALL
This PERMANENTLY DELETES:
  * jetson-codex Docker container, including its installed SDK / APT changes
  * jetson-codex:jp72-base and jetson-codex:jp72-full Docker images
  * SIX project-specific auth/config/SSH volumes and their saved credentials
  * Jetson Codex user systemd cloud-mount service and local rclone VFS cache
  * Local Jetson Codex configuration
  * Entire $REPO_DIR checkout, INCLUDING LOCAL WORKSPACE/SOURCE FILES
  * ALL reclaimable Docker BuildKit cache, including cache from other projects

Remote OneDrive/Google Drive files and shared rclone credentials are preserved.
Docker, NVIDIA runtime, unattended-upgrades and /etc/fuse.conf are also kept.
Before proceeding, ensure rclone has finished uploading all pending writes.

NOTICE
if [[ "$(printenv JETSON_CODEX_UNINSTALL_CONFIRM 2>/dev/null || :)" != "ERASE jetson-codex" ]]; then
  [[ -r /dev/tty && -w /dev/tty ]] ||
    fail "An interactive terminal is needed for confirmation."
  printf 'Type ERASE jetson-codex to continue: ' >/dev/tty
  IFS= read -r answer </dev/tty || fail 'Confirmation interrupted.'
  [[ "$answer" == "ERASE jetson-codex" ]] || fail 'Cancelled. No changes made.'
fi

mount="$HOME/jetson-codex-cloud"
unit="$HOME/.config/systemd/user/jetson-codex-cloud.service"
if [[ -f "$unit" ]]; then
  grep -Fq 'Description=Jetson Codex cloud project filesystem' "$unit" ||
    fail "Unexpected systemd unit at $unit. Refusing to touch it."
  if systemctl --user is-active --quiet jetson-codex-cloud.service; then
    status="$(systemctl --user status jetson-codex-cloud.service --no-pager -l 2>/dev/null || true)"
    if grep -Eq 'to upload [1-9][0-9]*|uploading [1-9][0-9]*' <<< "$status"; then
      fail 'Rclone reports outstanding uploads. Let them finish before uninstalling.'
    fi
  fi
fi
if mountpoint -q "$mount"; then
  [[ "$(findmnt -n -o FSTYPE -T "$mount" 2>/dev/null)" == fuse.rclone ]] ||
    fail "Unexpected filesystem at $mount. Refusing to unmount."
fi

USE_SUDO=0
if command -v docker >/dev/null 2>&1; then
  if ! docker info >/dev/null 2>&1; then
    if sudo docker info >/dev/null 2>&1; then
      USE_SUDO=1
    else
      fail 'Docker daemon is inaccessible. Nothing removed.'
    fi
  fi
fi
dock() {
  if [[ "$USE_SUDO" == 1 ]]; then sudo docker "$@"; else docker "$@"; fi
}
if command -v docker >/dev/null 2>&1 && dock container inspect jetson-codex >/dev/null 2>&1; then
  current_image="$(dock inspect --format '{{.Config.Image}}' jetson-codex)"
  case "$current_image" in
    jetson-codex:jp72-base|jetson-codex:jp72-full) ;;
    *) fail "Container jetson-codex uses unrelated image $current_image. Nothing removed." ;;
  esac
fi

# Remove Docker bind-mount users first, then unmount FUSE. Never rm -rf a
# mounted cloud folder; write-back cache is cleared only after unmount.
if command -v docker >/dev/null 2>&1 && dock container inspect jetson-codex >/dev/null 2>&1; then
  say 'Removing managed container and its post-installed writable layer.'
  dock rm -f jetson-codex >/dev/null || fail 'Container removal failed.'
fi
if [[ -f "$unit" ]]; then
  say 'Disabling Jetson Codex cloud-mount user service.'
  systemctl --user stop jetson-codex-cloud.service ||
    fail 'Cannot stop cloud mount service. Local VFS cache retained.'
  systemctl --user disable jetson-codex-cloud.service ||
    fail 'Cannot disable cloud mount service.'
fi
if mountpoint -q "$mount"; then
  command -v fusermount3 >/dev/null 2>&1 ||
    fail 'Cannot unmount cloud: fusermount3 missing.'
  fusermount3 -u "$mount" ||
    fail 'Cloud mount busy; close users and retry. Cache not removed.'
fi
if mountpoint -q "$mount"; then
  fail 'Cloud mount still active. Refusing cache deletion.'
fi
if [[ -f "$unit" ]]; then
  rm -f -- "$unit"
  systemctl --user daemon-reload || fail 'Cannot reload systemd user manager.'
fi

if command -v docker >/dev/null 2>&1; then
  for image in jetson-codex:jp72-base jetson-codex:jp72-full; do
    if dock image inspect "$image" >/dev/null 2>&1; then
      say "Removing owned image $image."
      dock image rm "$image" >/dev/null || fail "Image $image still in use."
    fi
  done
  for volume in jetson-codex-auth jetson-github-auth jetson-git-config \
                jetson-codex-git-ssh jetson-codex-gitlab-auth jetson-codex-azure-auth; do
    if dock volume inspect "$volume" >/dev/null 2>&1; then
      say "Removing dedicated volume $volume (credentials will be lost)."
      dock volume rm "$volume" >/dev/null || fail "Volume $volume still in use."
    fi
  done
  # BuildKit caches cannot be reliably attributed to this one project.
  # The user explicitly confirmed that unrelated build caches are included.
  say 'Pruning all reclaimable BuildKit cache, including other projects.'
  dock buildx prune --all --force || fail 'BuildKit cache cleanup failed.'
fi

config="$HOME/.config/jetson-codex"
cache="$HOME/.cache/jetson-codex"
[[ ! -d "$cache" ]] || rm -rf --one-file-system -- "$cache"
[[ ! -d "$config" ]] || rm -rf --one-file-system -- "$config"
if [[ -d "$mount" ]]; then
  rmdir -- "$mount" 2>/dev/null ||
    say "Preserving unexpected local files in mountpoint $mount."
fi
if [[ -d "$REPO_DIR" ]]; then
  say "Removing $REPO_DIR, including local workspace files."
  rm -rf --one-file-system -- "$REPO_DIR" ||
    fail 'Checkout removal failed.'
fi
say 'Complete local uninstall finished. Cloud files and shared host software preserved.'
