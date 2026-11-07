#!/usr/bin/env bash
# Read-only checks. Nonzero exit means intervention required.
set -uo pipefail
failures=0
ok(){ printf 'OK   %s\n' "$*"; }
bad(){ printf 'FAIL %s\n' "$*"; failures=$((failures+1)); }
warn(){ printf 'WARN %s\n' "$*"; }
if [[ -f /etc/nv_tegra_release ]] && grep -q '^# R39 (release), REVISION: 2.0' /etc/nv_tegra_release; then ok 'JetPack 7.2.0'; else bad 'Expected JetPack 7.2.0'; fi
if docker info >/dev/null 2>&1; then ok 'Docker daemon'; else bad 'Docker daemon'; fi
if docker compose version >/dev/null 2>&1; then ok 'Compose'; else bad 'Compose'; fi
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx jetson-codex; then
  ok 'Codex container running'
  if docker exec jetson-codex codex login status >/dev/null 2>&1; then ok 'Codex authenticated'; else bad 'Codex not authenticated'; fi
  if docker exec jetson-codex test -d /workspace/projects; then ok 'Cloud path exposed to container'; else bad 'Cloud path missing in container'; fi
  if docker exec jetson-codex gh auth status >/dev/null 2>&1; then ok 'GitHub authenticated'; else warn 'GitHub CLI not authenticated'; fi
else bad 'Codex container not running'; fi
conf="${XDG_CONFIG_HOME:-$HOME/.config}/jetson-codex/storage.env"
if [[ -f "$conf" ]]; then
  # shellcheck disable=SC1090
  source "$conf"
  if mountpoint -q "$RCLONE_MOUNT"; then
    ok "Cloud FUSE mounted: $RCLONE_MOUNT"
    if timeout 20 rclone lsf "$RCLONE_SOURCE" --max-depth 1 >/dev/null 2>&1; then ok 'Cloud remote reachable'; else bad 'Cloud remote unreachable'; fi
  else bad "Cloud mount not active: $RCLONE_MOUNT"; fi
  if systemctl --user is-enabled --quiet jetson-codex-cloud.service; then ok 'Cloud mount enabled at login'; else bad 'Cloud mount service disabled'; fi
else warn 'Cloud storage not configured'; fi
df -h / | tail -n 1
docker system df 2>/dev/null || true
exit "$failures"
