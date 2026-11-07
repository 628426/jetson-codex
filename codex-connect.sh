#!/usr/bin/env bash
# Persistent Git hosting connections for Codex, within the container.
# Safe to rerun. Keys and provider credentials live in named Docker volumes.
set -Eeuo pipefail
umask 077
SSH_DIR="$HOME/.ssh"
HOST_DIR="$SSH_DIR/jetson-hosts"
mkdir -p "$SSH_DIR" "$HOST_DIR"
chmod 700 "$SSH_DIR" "$HOST_DIR"
[[ -e "$SSH_DIR/config" ]] || touch "$SSH_DIR/config"
chmod 600 "$SSH_DIR/config"
if ! grep -Fxq 'Include ~/.ssh/jetson-hosts/*.conf' "$SSH_DIR/config"; then
  temp="$(mktemp "$SSH_DIR/config.tmp.XXXXXX")"
  printf '%s\n' 'Include ~/.ssh/jetson-hosts/*.conf' > "$temp"
  cat "$SSH_DIR/config" >> "$temp"
  mv "$temp" "$SSH_DIR/config"
fi

say() { printf '\n[Git providers] %s\n' "$*"; }
warn() { printf '[Git providers] WARNING: %s\n' "$*" >&2; }
ask() {
  local result
  printf '%s' "$1" >/dev/tty
  IFS= read -r result </dev/tty
  REPLY="$result"
}
valid_host() {
  local value="$1"
  [[ -n "$value" && "${#value}" -le 253 &&
     "$value" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ &&
     "$value" != *..* && "$value" != *.-* && "$value" != *-.* ]]
}
# Called with a provider identifier, hostname and key algorithm.
# SSH key material is generated once and never overwritten on reruns.
ensure_key() {
  local id="$1" host="$2" type="$3" key safe
  safe="$(printf '%s' "$id" | tr -c 'A-Za-z0-9._-' '_')"
  if [[ "$type" == "rsa" ]]; then
    key="$SSH_DIR/id_rsa_jetson_$safe"
  else
    key="$SSH_DIR/id_ed25519_jetson_$safe"
  fi
  if [[ ! -f "$key" ]]; then
    say "Generating a dedicated $type SSH key for $host."
    if [[ "$type" == "rsa" ]]; then
      ssh-keygen -q -t rsa -b 3072 -N '' -C "jetson-codex:$host" -f "$key"
    else
      ssh-keygen -q -t ed25519 -N '' -C "jetson-codex:$host" -f "$key"
    fi
  fi
  chmod 600 "$key"
  if [[ ! -f "$key.pub" ]]; then
    ssh-keygen -y -f "$key" > "$key.pub"
  fi
  chmod 644 "$key.pub"
  local conf="$HOST_DIR/$safe.conf"
  # One managed config file per provider/host. No global SSH overrides.
  printf 'Host %s\n  HostName %s\n  User git\n  IdentityFile %s\n  IdentitiesOnly yes\n  PreferredAuthentications publickey\n' \
    "$host" "$host" "$key" > "$conf"
  chmod 600 "$conf"
  KEY_FILE="$key"
  KEY_ID="$safe"
  say "Public key fingerprint: $(ssh-keygen -lf "$key.pub" | awk '{print $2}')"
}
print_key() {
  say "Paste this PUBLIC key into the provider's SSH keys page:"
  cat "$KEY_FILE.pub"
}
mark_linked() { touch "$SSH_DIR/.jetson-linked-$KEY_ID"; }
link_github() {
  local host="$1" id="$2"
  ensure_key "$id" "$host" ed25519
  if ! gh auth status --hostname "$host" >/dev/null 2>&1; then
    say "GitHub device login for $host. The CLI prints a URL and one-time code."
    if ! gh auth login --hostname "$host" --git-protocol ssh --web --skip-ssh-key; then
      warn "GitHub login not completed for $host."
      return 1
    fi
  else
    say "GitHub CLI already authenticated to $host."
  fi
  if [[ ! -f "$SSH_DIR/.jetson-linked-$KEY_ID" ]]; then
    if GH_HOST="$host" gh ssh-key add "$KEY_FILE.pub" --title "jetson-codex $(hostname)" ; then
      mark_linked
      say "SSH key registered on $host."
    else
      warn "Automatic key registration failed. Add the public key manually."
      print_key
      if [[ "$host" == "github.com" ]]; then
        say "Open https://github.com/settings/keys"
      else
        say "Open https://$host/settings/keys"
      fi
    fi
  else
    say "SSH key previously registered on $host; leaving it alone."
  fi
}
link_gitlab() {
  local host="$1" id="$2"
  ensure_key "$id" "$host" ed25519
  if ! glab auth status --hostname "$host" >/dev/null 2>&1; then
    say "GitLab device login for $host. Open the verification URL it prints."
    if ! glab auth login --hostname "$host" --git-protocol ssh --device; then
      warn "Device OAuth requires a recent GitLab instance and suitable OAuth configuration."
      say "Falling back to GitLab's interactive login (which can accept a personal access token)."
      glab auth login --hostname "$host" --git-protocol ssh || return 1
    fi
  else
    say "GitLab CLI already authenticated to $host."
  fi
  if [[ ! -f "$SSH_DIR/.jetson-linked-$KEY_ID" ]]; then
    if GITLAB_HOST="$host" glab ssh-key add "$KEY_FILE.pub" -t "jetson-codex $(hostname)" --usage-type auth; then
      mark_linked
      say "SSH key registered with $host."
    else
      warn "Automatic GitLab SSH key registration failed."
      print_key
      say "Open https://$host/-/user_settings/ssh_keys and add the public key."
    fi
  else
    say "GitLab key previously registered on $host; leaving it alone."
  fi
}
link_bitbucket() {
  ensure_key bitbucket-cloud bitbucket.org ed25519
  if [[ -f "$SSH_DIR/.jetson-linked-$KEY_ID" ]]; then
    say "Bitbucket SSH key was previously registered."
    return
  fi
  say "Open https://bitbucket.org/account/settings/ssh-keys/ in your PC browser."
  say "Add the following to your PERSONAL SSH keys (not a read-only repository access key):"
  print_key
  ask "Press Enter once the public key has been saved, or type 'skip': "
  [[ "$REPLY" == "skip" ]] && return
  mark_linked
  say "Bitbucket is configured for Git over SSH. Repository permissions still apply."
}
# For private Bitbucket Data Center/Server deployments, use the SSH clone
# hostname and port supplied by that installation (often 7999).
link_bitbucket_private() {
  local host port
  ask "Bitbucket Data Center hostname (DNS name, not URL): "
  host="$REPLY"
  valid_host "$host" || { warn "Invalid hostname."; return 1; }
  ask "SSH port [7999]: "
  port="${REPLY:-7999}"
  [[ "$port" =~ ^[0-9]{1,5}$ ]] && (( 10#$port > 0 && 10#$port <= 65535 )) \
    || { warn "Invalid SSH port."; return 1; }
  ensure_key "bitbucket-$host" "$host" ed25519
  printf '  Port %s\n' "$port" >> "$HOST_DIR/$KEY_ID.conf"
  if [[ -f "$SSH_DIR/.jetson-linked-$KEY_ID" ]]; then
    say "This Bitbucket server's SSH key was previously registered."
    return
  fi
  say "Open https://$host and add the public SSH key under your user account's SSH keys."
  print_key
  ask "Press Enter once the public key has been saved, or type 'skip': "
  [[ "$REPLY" == "skip" ]] && return
  mark_linked
  say "Use the SSH clone URL provided by Bitbucket Data Center. Git push/pull is ready."
}
link_azure() {
  # Azure DevOps Services currently supports RSA, not Ed25519 SSH user keys.
  ensure_key azure-devops ssh.dev.azure.com rsa
  if [[ -f "$SSH_DIR/.jetson-linked-$KEY_ID" ]]; then
    say "Azure DevOps SSH key was previously registered."
  else
    say "Open your Azure DevOps organisation in the PC browser."
    say "Choose User settings > SSH public keys > New Key."
    print_key
    ask "Press Enter once the public key has been saved, or type 'skip': "
    [[ "$REPLY" == "skip" ]] && return
    mark_linked
  fi
  if command -v az >/dev/null 2>&1; then
    if ! az account show >/dev/null 2>&1; then
      ask "Link Azure CLI for PRs, boards and pipelines using Microsoft device login? [y/N]: "
      if [[ "$REPLY" =~ ^[Yy]$ ]]; then
        say "Open https://microsoft.com/devicelogin and enter the code shown."
        az login --use-device-code --allow-no-subscriptions || warn "Azure CLI login not completed."
      fi
    else
      say "Azure CLI already authenticated."
    fi
  else
    warn "Azure CLI is unavailable. Git SSH still works, but az repos/boards commands will not."
  fi
}
link_private() {
  local provider="$1" host id
  ask "Enter the private $provider hostname (DNS name, not URL): "
  host="$REPLY"
  valid_host "$host" || { warn "Invalid hostname."; return 1; }
  if [[ "$provider" == "GitHub Enterprise" ]]; then
    id="ghe-$host"
    link_github "$host" "$id"
  else
    id="gitlab-$host"
    link_gitlab "$host" "$id"
  fi
}
status() {
  printf 'Git hosting tools: '
  for cmd in git ssh gh glab az; do
    if command -v "$cmd" >/dev/null 2>&1; then printf '%s=OK ' "$cmd"; else printf '%s=MISSING ' "$cmd"; fi
  done
  printf '\nConfigured SSH provider identities:\n'
  for file in "$HOST_DIR"/*.conf; do
    [[ -f "$file" ]] || continue
    sed -n 's/^Host /  /p' "$file"
  done
  if gh auth status --hostname github.com >/dev/null 2>&1; then say "GitHub.com OAuth: linked"; else say "GitHub.com OAuth: not linked"; fi
  if glab auth status --hostname gitlab.com >/dev/null 2>&1; then say "GitLab.com OAuth: linked"; else say "GitLab.com OAuth: not linked"; fi
}
if [[ "${1:-}" == "--status" ]]; then status; exit 0; fi
(( $# == 0 )) || { echo "Usage: codex-connect [--status]" >&2; exit 2; }
[[ -r /dev/tty && -w /dev/tty ]] || { echo "Run interactively: docker exec -it jetson-codex codex-connect" >&2; exit 2; }
while true; do
  printf '\n====== Codex Git provider connections ======\n' >/dev/tty
  printf '  1) GitHub.com\n  2) GitHub Enterprise Server / private GitHub host\n' >/dev/tty
  printf '  3) GitLab.com\n  4) GitLab self-managed / private GitLab host\n' >/dev/tty
  printf '  5) Bitbucket Cloud\n  6) Azure DevOps Services\n  7) Connection status\n  8) Bitbucket Data Center (private host)\n  0) Done\n' >/dev/tty
  ask "Choose [0-8]: "
  case "$REPLY" in
    1) link_github github.com github-com || true ;;
    2) link_private "GitHub Enterprise" || true ;;
    3) link_gitlab gitlab.com gitlab-com || true ;;
    4) link_private "GitLab" || true ;;
    5) link_bitbucket || true ;;
    6) link_azure || true ;;
    7) status ;;
    8) link_bitbucket_private || true ;;
    0|"") break ;;
    *) warn "Invalid choice." ;;
  esac
done
say "Connections persist across image rebuilds and container recreation."
say "Run codex-connect again from inside the container to link more accounts."
