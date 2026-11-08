#!/usr/bin/env bash
# Single-version toolchain image: all language defaults are pinned at build time.
# Never install/download a second compiler version when a container starts.
set -euo pipefail
selectors=(
  CODEX_ENV_PYTHON_VERSION CODEX_ENV_NODE_VERSION
  CODEX_ENV_RUBY_VERSION CODEX_ENV_RUST_VERSION
  CODEX_ENV_GO_VERSION CODEX_ENV_JAVA_VERSION
  CODEX_ENV_PHP_VERSION CODEX_ENV_SWIFT_VERSION
)
for variable in "${selectors[@]}"; do
  if [[ -n "${!variable:-}" ]]; then
    printf 'Unsupported runtime override %s=%s: jetson-codex is a single-version image. Remove the override or rebuild for a different version.\n' \
      "$variable" "${!variable}" >&2
    exit 2
  fi
done
