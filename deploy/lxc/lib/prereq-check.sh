#!/usr/bin/env bash
# vidi/deploy/lxc/lib/prereq-check.sh
# Validates manual prerequisites. Exits non-zero with a clear message naming
# the missing prereq + the command to fix it. Run as the first step of every
# provision.sh / deploy.sh invocation.
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &>/dev/null && pwd )"
source "${SCRIPT_DIR}/common.sh"
read_versions

log_info "Verifying manual prerequisites…"

# 1. cloudflared CLI on the Mac
if ! command -v cloudflared >/dev/null 2>&1; then
  die "cloudflared CLI not found on this host. Install with: brew install cloudflared"
fi

# 2. ~/.cloudflared/cert.pem (proof of `cloudflared tunnel login`)
CERT="${HOME}/.cloudflared/cert.pem"
if [ ! -f "$CERT" ]; then
  die "Cloudflare cert.pem missing at $CERT. Run: cloudflared tunnel login"
fi

# Tighten cert.pem perms if loose. stat differs between macOS and Linux.
mode=$(stat -f '%OLp' "$CERT" 2>/dev/null || stat -c '%a' "$CERT")
if [ "$mode" != "600" ]; then
  log_warn "cert.pem mode is $mode (expected 600). Fixing…"
  chmod 0600 "$CERT"
fi

# 3. Cloudflare API reachable + cert.pem valid (proxy: zone visible).
if ! cloudflared tunnel list --output json >/dev/null 2>&1; then
  die "cloudflared cannot reach Cloudflare API with this cert. Re-run: cloudflared tunnel login"
fi

# 4. SSH connectivity to LXC
if ! ssh -o BatchMode=yes -o ConnectTimeout=5 \
        "${LXC_USER}@${LXC_HOST}" 'true' 2>/dev/null; then
  die "Cannot SSH to ${LXC_USER}@${LXC_HOST}. Set up key auth: ssh-copy-id ${LXC_USER}@${LXC_HOST}"
fi

# 5. Root or passwordless sudo on LXC (needed for apt + systemctl)
remote_uid=$(ssh -o BatchMode=yes "${LXC_USER}@${LXC_HOST}" 'id -u' 2>/dev/null)
if [ "$remote_uid" != "0" ]; then
  if ! ssh -o BatchMode=yes "${LXC_USER}@${LXC_HOST}" 'sudo -n true' 2>/dev/null; then
    die "${LXC_USER}@${LXC_HOST} is not root and lacks passwordless sudo."
  fi
fi

log_ok "All prerequisites satisfied."
