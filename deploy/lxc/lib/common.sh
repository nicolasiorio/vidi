#!/usr/bin/env bash
# vidi/deploy/lxc/lib/common.sh
# Shared helpers. Sourced by provision.sh, deploy.sh, and prereq-check.sh.
# Never executed directly.

[ -n "${VIDI_COMMON_SOURCED:-}" ] && return 0
VIDI_COMMON_SOURCED=1

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

# Walks up from the calling script's directory to find VERSIONS.
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

# SSH connection multiplexing — first call opens a master socket, all
# subsequent calls reuse it. Cuts ~14 handshakes per provision run.
# Path stays under macOS's 104-char Unix-socket limit (which rules out
# the SHA-256 %C token + a long $TMPDIR).
SSH_OPTS=(
  -T
  -o BatchMode=yes
  -o ConnectTimeout=10
  -o ControlMaster=auto
  -o "ControlPath=/tmp/vidi-ssh-%h-%r"
  -o ControlPersist=60s
)

# Usage: ssh_run "uname -a"
ssh_run() {
  ssh "${SSH_OPTS[@]}" "${LXC_USER}@${LXC_HOST}" "$@"
}

# Usage: ssh_remote <<'REMOTE' ... REMOTE
ssh_remote() {
  ssh "${SSH_OPTS[@]}" "${LXC_USER}@${LXC_HOST}" 'bash -s'
}

# Atomic remote write: stream local file to <dst>.tmp, then rename.
ssh_push_file() {
  local src="$1" dst="$2"
  ssh "${SSH_OPTS[@]}" "${LXC_USER}@${LXC_HOST}" \
    "cat > '${dst}.tmp' && mv '${dst}.tmp' '${dst}'" < "$src"
}
