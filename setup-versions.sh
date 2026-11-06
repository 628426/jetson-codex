#!/usr/bin/env bash
set -euo pipefail
# Compatible selectors, modelled on OpenAI codex-universal's CODEX_ENV_* scheme.
# This operates on already-installed toolchains; it doesn't download at startup.
use_mise() {
  local key="$1" package="$2"
  if [[ -n "${!key:-}" ]]; then
    mise use --global "${package}@${!key}"
  fi
}
use_mise CODEX_ENV_PYTHON_VERSION python
use_mise CODEX_ENV_NODE_VERSION node
use_mise CODEX_ENV_RUBY_VERSION ruby
use_mise CODEX_ENV_GO_VERSION go
use_mise CODEX_ENV_JAVA_VERSION java
if [[ -n "${CODEX_ENV_RUST_VERSION:-}" ]]; then rustup default "${CODEX_ENV_RUST_VERSION}"; fi
if [[ -n "${CODEX_ENV_PHP_VERSION:-}" ]]; then phpenv global "${CODEX_ENV_PHP_VERSION}snapshot"; fi
if [[ -n "${CODEX_ENV_SWIFT_VERSION:-}" ]]; then
  [[ -f "${SWIFTLY_HOME_DIR:-/root/.local/share/swiftly}/env.sh" ]] || { echo 'Swift was not installed' >&2; exit 1; }
  source "${SWIFTLY_HOME_DIR:-/root/.local/share/swiftly}/env.sh"
  swiftly use "${CODEX_ENV_SWIFT_VERSION}"
fi
