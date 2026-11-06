#!/usr/bin/env bash
set -euo pipefail
/opt/jetson-codex/setup-versions.sh
exec "$@"
