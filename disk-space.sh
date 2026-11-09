#!/usr/bin/env bash
# Aggressive Docker disk reclamation without deleting volumes or containers.
# Safe to call as: disk-space.sh pre | monitor PARENT_PID | post
set -Eeuo pipefail

phase="${1:-}"
log() { printf '[disk-space] %s\n' "$*" >&2; }

docker_root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
free_kib() {
  [[ -n "$docker_root" && -d "$docker_root" ]] || return 1
  df -Pk "$docker_root" | awk 'NR==2 {print $4}'
}
report() {
  local free
  if free="$(free_kib)" && [[ "$free" =~ ^[0-9]+$ ]]; then
    log "Docker root: $docker_root; available: $(( free / 1024 / 1024 )) GiB"
  else
    log "Unable to read free space at Docker's data root."
  fi
}

# BuildKit will only reclaim records that are not actively in use.
# A full --all wipe sacrifices future cache hits in exchange for free space.
clear_build_cache() {
  if ! docker buildx prune --all --force --filter 'inuse=false'; then
    log "WARNING: BuildKit pruning failed. Continuing; no Docker data volume touched."
  fi
}
clear_dangling_images() {
  if ! docker image prune --force; then
    log "WARNING: Dangling image cleanup failed; no running containers touched."
  fi
}

case "$phase" in
  pre)
    log "Before build: discarding ALL reclaimable BuildKit cache, including other projects."
    report
    clear_build_cache
    clear_dangling_images
    report
    ;;
  monitor)
    parent_pid="${2:-}"
    [[ "$parent_pid" =~ ^[0-9]+$ ]] || { log "Parent PID required"; exit 2; }
    # Check while the build runs. At <12 GiB, prune aggressively. The
    # 20-second cadence limits contention with the active BuildKit solve.
    log "Disk watcher active; prune unused cache below 12 GiB free."
    while kill -0 "$parent_pid" 2>/dev/null; do
      sleep 20
      kill -0 "$parent_pid" 2>/dev/null || exit 0
      available="$(free_kib)" || continue
      [[ "$available" =~ ^[0-9]+$ ]] || continue
      if (( available < 12 * 1024 * 1024 )); then
        log "LOW SPACE: $((available / 1024 / 1024)) GiB free; removing reclaimable BuildKit cache now."
        clear_build_cache
        # Image prune can also reclaim dangling layers once a build no
        # longer references them. Docker refuses to remove in-use images.
        clear_dangling_images
        report
        remaining="$(free_kib)" || continue
        if [[ "$remaining" =~ ^[0-9]+$ ]] && (( remaining < 3 * 1024 * 1024 )); then
          log "CRITICAL: <3 GiB free even after pruning. Nothing else can be safely removed automatically."
        fi
      fi
    done
    ;;
  post)
    log "Image is running and hardware-tested. Discarding remaining BuildKit cache."
    clear_build_cache
    clear_dangling_images
    report
    docker system df || true
    ;;
  *)
    log "Usage: disk-space.sh {pre|monitor PARENT_PID|post}"
    exit 2
    ;;
esac
