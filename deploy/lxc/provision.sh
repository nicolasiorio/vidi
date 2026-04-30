#!/usr/bin/env bash
# vidi/deploy/lxc/provision.sh
# One-shot LXC bootstrap. Idempotent — re-running is always safe.
# Currently implements Phases 1–3 (foundation + system + Postgres).
# Phases 4–7 land in subsequent build batches.
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &>/dev/null && pwd )"
source "${SCRIPT_DIR}/lib/common.sh"
read_versions

# ─── Prereq check ─────────────────────────────────────────────────────
"${SCRIPT_DIR}/lib/prereq-check.sh"

log_info "Provisioning ${LXC_USER}@${LXC_HOST} (vidi → ${DOMAIN})"

# ─── Phase 2.1: apt baseline + locale + timezone + 2GB swap ───────────
log_info "Phase 2.1 — system baseline (apt + locale + tz + swap)"
ssh_remote <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get full-upgrade -y -qq

# Locale en_US.UTF-8
if ! locale -a 2>/dev/null | grep -qi '^en_US\.utf8$'; then
  apt-get install -y -qq locales
  sed -i 's/^# *en_US\.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
  locale-gen en_US.UTF-8 >/dev/null
  update-locale LANG=en_US.UTF-8
fi

# Timezone UTC
if [ "$(timedatectl show --property=Timezone --value 2>/dev/null || true)" != "UTC" ]; then
  timedatectl set-timezone UTC
fi

# Memory floor. Crystal compile peaks ~2.5GB. LXC swap is host-managed
# (pct set <CTID> -swap N); the kernel blocks `swapon` from inside the
# container, so we don't try to create an in-LXC swap file. If RAM is
# insufficient, fail with a clear instruction to bump it in Proxmox.
mem_total_mb=$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo)
if [ "$mem_total_mb" -lt 2500 ]; then
  echo "ERROR: LXC has only ${mem_total_mb} MB RAM; Crystal compile needs ~2.5GB." >&2
  echo "Bump from the Proxmox host: pct set <CTID> -memory 4096 -swap 2048" >&2
  exit 1
fi
REMOTE
log_ok "Phase 2.1 done."

# ─── Phase 2.2: build deps + invidious system user ────────────────────
log_info "Phase 2.2 — build deps + invidious user"
ssh_remote <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get install -y -qq \
  libssl-dev libxml2-dev libyaml-dev libgmp-dev libreadline-dev \
  librsvg2-bin libsqlite3-dev zlib1g-dev libpcre2-dev libevent-dev \
  fonts-open-sans pwgen git make gettext-base jq curl wget ca-certificates \
  openssl

if ! id invidious >/dev/null 2>&1; then
  useradd -m -s /bin/bash invidious
  passwd -l invidious >/dev/null
fi
REMOTE
log_ok "Phase 2.2 done."

# ─── Phase 3.1: PostgreSQL + secrets + role/db ────────────────────────
log_info "Phase 3.1 — PostgreSQL + secrets + role/db"
ssh_remote <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get install -y -qq postgresql
systemctl enable --now postgresql

install -d -m 0755 -o root -g root /etc/invidious

# Generate secrets.env once, then never rotate.
# SERVER_SECRET_KEY MUST be exactly 16 chars (upstream constraint —
# Invidious refuses to start if the length differs).
if [ ! -f /etc/invidious/secrets.env ]; then
  POSTGRES_PASSWORD=$(openssl rand -hex 24)
  HMAC_KEY=$(openssl rand -hex 32)
  SERVER_SECRET_KEY=$(openssl rand -hex 8)
  umask 077
  cat > /etc/invidious/secrets.env <<EOF
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
HMAC_KEY=$HMAC_KEY
SERVER_SECRET_KEY=$SERVER_SECRET_KEY
EOF
  chown invidious:invidious /etc/invidious/secrets.env
  chmod 0600 /etc/invidious/secrets.env
fi

# Source secrets so we can use POSTGRES_PASSWORD below.
set -a; source /etc/invidious/secrets.env; set +a

# Postgres role (idempotent). Use runuser instead of sudo — bare Debian
# containers don't ship sudo, and we're already root over SSH so don't need it.
# Peer auth lets the postgres unix user connect without a password.
if ! runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='invidious'" | grep -q '^1$'; then
  runuser -u postgres -- psql -c "CREATE ROLE invidious LOGIN PASSWORD '$POSTGRES_PASSWORD'" >/dev/null
fi

# Database (idempotent).
if ! runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_database WHERE datname='invidious'" | grep -q '^1$'; then
  runuser -u postgres -- createdb -O invidious invidious
fi
REMOTE
log_ok "Phase 3.1 done."

log_ok "Provision complete (Phases 1–3)."
log_info "Next batch will add: Crystal toolchain, Invidious build, companion, cloudflared, theme deploy."
