#!/usr/bin/env bash
# vidi/deploy/lxc/lib/common.sh
# Shared helpers. Sourced by provision.sh, deploy.sh, and prereq-check.sh.
# Never executed directly.

# Guard against double-sourcing.
[ -n "${VIDI_COMMON_SOURCED:-}" ] && return 0
VIDI_COMMON_SOURCED=1

# ── Logging ──────────────────────────────────────────────────────────
if [ -t 2 ]; then
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
  C_RESET=$'\033[0m'
else
  C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_RESET=''
fi

log_info() { printf '%s[INFO]%s %s\n' "$C_BLUE"   "$C_RESET" "$*" >&2; }
log_ok()   { printf '%s[ OK ]%s %s\n' "$C_GREEN"  "$C_RESET" "$*" >&2; }
log_warn() { printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
log_err()  { printf '%s[ERR ]%s %s\n' "$C_RED"    "$C_RESET" "$*" >&2; }
die()      { log_err "$*"; exit 1; }

# ── Versions ─────────────────────────────────────────────────────────
# Walks up from the calling script's directory to find VERSIONS, sources it.
read_versions() {
  local dir
  dir="$( cd "$( dirname "${BASH_SOURCE[1]}" )" && pwd )"
  while [ "$dir" != "/" ]; do
    if [ -f "$dir/VERSIONS" ]; then
      set -a; source "$dir/VERSIONS"; set +a
      return 0
    fi
    dir="$( dirname "$dir" )"
  done
  die "VERSIONS file not found (searched up from ${BASH_SOURCE[1]})"
}

# ── SSH ──────────────────────────────────────────────────────────────
# Run a single command on the LXC. Inherits stdin/stdout/stderr.
# Usage: ssh_run "uname -a"
ssh_run() {
  : "${LXC_USER:?LXC_USER not set — call read_versions first}"
  : "${LXC_HOST:?LXC_HOST not set — call read_versions first}"
  ssh -T -o BatchMode=yes -o ConnectTimeout=10 \
    "${LXC_USER}@${LXC_HOST}" "$@"
}

# Run a multi-line bash script on the LXC by piping stdin → `bash -s`.
# Usage:
#   ssh_remote <<'REMOTE'
#     set -euo pipefail
#     apt-get update
#   REMOTE
ssh_remote() {
  : "${LXC_USER:?LXC_USER not set — call read_versions first}"
  : "${LXC_HOST:?LXC_HOST not set — call read_versions first}"
  ssh -T -o BatchMode=yes -o ConnectTimeout=10 \
    "${LXC_USER}@${LXC_HOST}" 'bash -s'
}

# Push a local file to the LXC, atomically (write to .tmp, then rename).
# Usage: ssh_push_file <local-path> <remote-path>
ssh_push_file() {
  local src="$1" dst="$2"
  : "${LXC_USER:?LXC_USER not set — call read_versions first}"
  : "${LXC_HOST:?LXC_HOST not set — call read_versions first}"
  [ -f "$src" ] || die "ssh_push_file: source file not found: $src"
  ssh -T -o BatchMode=yes "${LXC_USER}@${LXC_HOST}" \
    "cat > '${dst}.tmp' && mv '${dst}.tmp' '${dst}'" < "$src"
}

# ── Secrets ──────────────────────────────────────────────────────────
# Generate a hex secret. Arg = byte length (output is 2*N hex chars).
# Example: gen_secret 8  → 16-char hex (used for SERVER_SECRET_KEY).
gen_secret() {
  local bytes="${1:-32}"
  openssl rand -hex "$bytes"
}

# ── Interaction ──────────────────────────────────────────────────────
# y/N prompt. Returns 0 on yes.
confirm() {
  local prompt="${1:-Continue?}" reply
  read -r -p "$prompt [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}
