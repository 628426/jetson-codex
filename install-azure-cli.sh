#!/usr/bin/env bash
# Install Azure CLI into the already-running Jetson container.
# A DNS/HTTPS failure must never replace a valid signing key with an empty file
# or write a broken APT source. This script is safe to rerun after failure.
set -Eeuo pipefail

log(){ printf '[azure-bootstrap] %s\n' "$*"; }
fail(){ log "ERROR: $*" >&2; exit 1; }

if command -v az >/dev/null 2>&1; then
  log 'Azure CLI already installed; no APT changes.'
  exit 0
fi

# Official Microsoft Azure CLI ARM64 Ubuntu 24.04 repository and signing key.
key_url='https://packages.microsoft.com/keys/microsoft.asc'
repo_url='https://packages.microsoft.com/repos/azure-cli/'
expected_fingerprint='BC528686B50D79E339D3721CEB3E94ADBE1229CF'
keyring_dir="\${AZURE_KEYRING_DIR:-/etc/apt/keyrings}"
sources_dir="\${AZURE_SOURCES_DIR:-/etc/apt/sources.list.d}"
keyring="$keyring_dir/microsoft-azure.gpg"
source_file="$sources_dir/azure-cli.list"

# No side effects outside the container until the download is complete and
# Microsoft release-key fingerprint is checked.
raw_key="$(mktemp /tmp/jetson-ms-key.XXXXXXXX)"
staged_key=''
staged_source=''
cleanup(){
  rm -f -- "$raw_key"
  [[ -z "$staged_key" ]] || rm -f -- "$staged_key"
  [[ -z "$staged_source" ]] || rm -f -- "$staged_source"
}
trap cleanup EXIT

log 'Downloading Microsoft signing key with bounded DNS/TLS retries.'
# --retry alone does not cover DNS failures. --retry-all-errors does.
# Use --output (not a curl | gpg pipeline): retrying a pipe can concatenate
# failed and successful responses and corrupt a signing key.
if ! curl --fail --silent --show-error --location \
     --retry 4 --retry-all-errors --retry-delay 3 --retry-max-time 120 \
     --connect-timeout 10 --max-time 35 \
     --output "$raw_key" "$key_url"; then
  log 'Microsoft package host DNS/HTTPS failed from inside the container.'
  if command -v getent >/dev/null 2>&1; then
    getent ahostsv4 packages.microsoft.com >&2 ||
      log 'DNS lookup for packages.microsoft.com also failed.'
  fi
  if [[ -r /etc/resolv.conf ]]; then
    log 'Container DNS resolvers (nameserver lines):'
    grep -E '^[[:space:]]*nameserver[[:space:]]' /etc/resolv.conf >&2 || true
  fi
  fail 'Network unresolved. Existing APT configuration and installed tools untouched. Fix DNS/connectivity and rerun install.sh.'
fi

[[ -s "$raw_key" ]] || fail 'Microsoft signing key download is empty.'
fingerprint="$(gpg --batch --with-colons --show-keys "$raw_key" 2>/dev/null |
  awk -F: '$1=="fpr" {print toupper($10); exit}')"
[[ "$fingerprint" == "$expected_fingerprint" ]] ||
  fail "Downloaded Microsoft signing key fingerprint $fingerprint did not match published fingerprint; refusing to trust it."

mkdir -p "$keyring_dir" "$sources_dir"
staged_key="$(mktemp "$keyring_dir/.microsoft-azure.gpg.XXXXXXXX")"
gpg --batch --yes --dearmor -o "$staged_key" "$raw_key" ||
  fail 'Cannot dearmor verified Microsoft signing key.'
[[ -s "$staged_key" ]] || fail 'Generated Microsoft keyring is empty.'
chmod 0644 "$staged_key"

if [[ -f "$keyring" ]] && cmp -s "$staged_key" "$keyring"; then
  log 'Microsoft signing key already correct; preserving existing file.'
else
  mv -f -- "$staged_key" "$keyring"
  staged_key=''
  log 'Installed verified Microsoft signing key.'
fi

staged_source="$(mktemp "$sources_dir/.azure-cli.list.XXXXXXXX")"
printf 'deb [arch=arm64 signed-by=%s] %s noble main\n' "$keyring" "$repo_url" > "$staged_source"
chmod 0644 "$staged_source"
if [[ -f "$source_file" ]] && cmp -s "$staged_source" "$source_file"; then
  log 'Azure CLI APT source already configured.'
else
  mv -f -- "$staged_source" "$source_file"
  staged_source=''
  log 'Configured Azure CLI repository for ARM64 Ubuntu 24.04.'
fi

# Treat unreachable indices as failures rather than silently reusing stale
# APT lists. Ubuntu Noble supports APT::Update::Error-Mode=any.
log 'Refreshing package indices and installing Azure CLI.'
apt-get -o APT::Update::Error-Mode=any -o Acquire::Retries=3 update ||
  fail 'APT cannot reach configured repositories. Correct network access and rerun.'
apt-get -y --no-install-recommends -o Acquire::Retries=3 install azure-cli ||
  fail 'Azure CLI APT installation failed. Existing container retained for retry.'
command -v az >/dev/null 2>&1 || fail 'Azure CLI package installed without an az executable.'
az --version
log 'Azure CLI installation complete.'
