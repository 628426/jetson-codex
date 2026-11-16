#!/usr/bin/env bash
# PID 1 command for a persistent post-provisioned Jetson container.
# On a Docker restart, restore the managed Codex Remote Control daemon
# if the CLI and prior ChatGPT authentication are both present.
# Fresh containers have not been provisioned yet; install.sh will enable
# Remote Control after installation and authentication on the first run.
set -Eeuo pipefail

if command -v codex >/dev/null 2>&1 \
  && timeout 20 codex login status >/dev/null 2>&1; then
  if timeout 45 codex remote-control start --json >/dev/null 2>&1; then
    printf '[jetson-codex] Restored authenticated Codex Remote Control after startup.\n'
  else
    printf '[jetson-codex] WARNING: Remote Control did not start. Retry with codex-remote.sh start on host.\n' >&2
  fi
fi

# No additional init system or duplicate copy of installed SDK tools.
exec sleep infinity
