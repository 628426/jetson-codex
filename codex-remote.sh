#!/usr/bin/env bash
# Enable the native Codex Remote Control daemon and print a one-time mobile
# pairing code. Codex itself stays INSIDE the persistent Docker container.
# Never store a pairing code or copy Codex credentials onto the Jetson host.
set -Eeuo pipefail

CONTAINER="${JETSON_CODEX_CONTAINER:-jetson-codex}"
OFFERED_MARKER=/root/.codex/.jetson-remote-code-offered

log() { printf '[codex-remote] %s\n' "$*"; }
fail() { log "ERROR: $*" >&2; exit 1; }

require_container() {
  docker ps --filter "name=^/${CONTAINER}$" --format '{{.Names}}' | grep -Fxq "$CONTAINER" \
    || fail "Container $CONTAINER is not running. Start it without recreating it."
  docker exec "$CONTAINER" codex remote-control --help >/dev/null 2>&1 \
    || fail "Installed Codex CLI does not support native remote-control. Update Codex first."
}

authenticated() {
  docker exec "$CONTAINER" codex login status >/dev/null 2>&1
}

ensure_started() {
  if ! authenticated; then
    log "Codex is not signed in. Pairing requires ChatGPT authentication first."
    return 2
  fi
  # Official CLI 'start' reuses the managed daemon if already running.
  # JSON is suppressed here; the environment ID and code do not belong in logs.
  if ! docker exec "$CONTAINER" codex remote-control start --json >/dev/null; then
    log "Remote Control failed to start. Check the Codex CLI/account eligibility."
    return 1
  fi
  log "Remote Control enabled on $CONTAINER (not evidence of mobile pairing)."
}

pair_now() {
  [[ ( -t 0 || -t 1 || -t 2 ) && -r /dev/tty && -w /dev/tty ]] \
    || fail "Pairing needs an interactive terminal to display the short-lived code."
  ensure_started || return 1
  printf '\n%s\n' \
    'Open ChatGPT on your phone, go to Codex/Remote and enter the code below.' \
    'Use the SAME ChatGPT account and workspace as the Jetson Codex CLI.' >/dev/tty
  # Code is printed ONLY to the user's TTY; never captured or persisted.
  if docker exec -it "$CONTAINER" codex remote-control pair </dev/tty >/dev/tty 2>&1; then
    docker exec "$CONTAINER" touch "$OFFERED_MARKER" \
      || log "Warning: pairing-offer marker could not be written."
    log "Code issued (not confirmation the phone has paired)."
    printf '%s\n' \
      'If the code expires or the mobile app cannot claim it, repeat:' \
      '  bash ~/jetson-codex/codex-remote.sh pair' >/dev/tty
  else
    log "Pairing code could not be issued. No pairing state has been recorded."
    return 1
  fi
}

auto_setup() {
  # Remote Control is optional; unsupported accounts must not break the
  # CUDA/SDK installation or cause an unrequested Docker rebuild.
  if ! authenticated; then
    log "Skipping Remote Control: Codex is not authenticated."
    log "After signing in, run: bash ~/jetson-codex/codex-remote.sh pair"
    return 0
  fi
  if ! ensure_started; then
    log "Remote Control unavailable; SDK setup remains intact."
    return 0
  fi
  if ! [[ ( -t 0 || -t 1 || -t 2 ) && -r /dev/tty && -w /dev/tty ]]; then
    log "No interactive terminal. Pair later: bash ~/jetson-codex/codex-remote.sh pair"
    return 0
  fi
  if docker exec "$CONTAINER" test -f "$OFFERED_MARKER"; then
    log "Pairing code was previously offered. No new code generated on this rerun."
    log "To generate another code: bash ~/jetson-codex/codex-remote.sh pair"
    return 0
  fi
  printf '\n%s\n' 'Pair Jetson Codex with the ChatGPT mobile app now? [Y/n] ' >/dev/tty
  IFS= read -r answer </dev/tty || answer=n
  if [[ -z "$answer" || "$answer" =~ ^[Yy]$ ]]; then
    pair_now || log "Pairing not completed. Run codex-remote.sh pair to retry."
  else
    log "Pairing declined. Run codex-remote.sh pair whenever you want."
  fi
}

case "${1:-}" in
  start) require_container; ensure_started ;;
  pair)  require_container; pair_now ;;
  auto)  require_container; auto_setup ;;
  *) printf '%s\n' 'Usage: codex-remote.sh {start|pair|auto}' >&2; exit 2 ;;
esac
