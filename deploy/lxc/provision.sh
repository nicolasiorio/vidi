#!/usr/bin/env bash
# vidi/deploy/lxc/provision.sh
# One-shot LXC bootstrap. Idempotent — re-running is always safe.
# Currently implements Phases 1–5 (foundation, system, Postgres, Invidious,
# companion). Phases 6–7 (cloudflared tunnel + theme deploy) land in the
# next build batch.
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

# ─── Phase 4.1: Install Crystal + clone Invidious at pinned tag ───────
log_info "Phase 4.1 — install Crystal + clone Invidious ${INVIDIOUS_TAG}"
ssh_remote <<REMOTE
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Crystal toolchain. Idempotent: install.sh handles existing source.
if ! command -v crystal >/dev/null 2>&1; then
  curl -fsSL https://crystal-lang.org/install.sh | bash
fi

# Clone or fetch Invidious. Run as the invidious user so it owns the tree.
SRC=/home/invidious/invidious
if [ ! -d "\$SRC/.git" ]; then
  runuser -u invidious -- git clone --quiet https://github.com/iv-org/invidious.git "\$SRC"
fi
cd "\$SRC"
if [ "\$(runuser -u invidious -- git describe --tags --exact-match 2>/dev/null || echo none)" != "${INVIDIOUS_TAG}" ]; then
  runuser -u invidious -- git fetch --tags --quiet origin
  runuser -u invidious -- git checkout --quiet "${INVIDIOUS_TAG}"
fi
REMOTE
log_ok "Phase 4.1 done."

# ─── Phase 4.3a: Render config.yml (must precede migrations) ──────────
# NOTE: Plan order was 4.2-then-4.3, but `./invidious --migrate` needs a
# working config.yml to connect to Postgres. We render config.yml here,
# build + migrate in 4.2, then install systemd units in 4.3b.
log_info "Phase 4.3a — render Invidious config.yml"
ssh_push_file "${SCRIPT_DIR}/config/invidious-config.yml.tpl" /tmp/invidious-config.yml.tpl
ssh_remote <<'REMOTE'
set -euo pipefail
install -d -m 0755 -o root -g root /etc/invidious
set -a; source /etc/invidious/secrets.env; set +a
envsubst < /tmp/invidious-config.yml.tpl > /etc/invidious/config.yml.tmp
mv /etc/invidious/config.yml.tmp /etc/invidious/config.yml
chmod 0640 /etc/invidious/config.yml
chown invidious:invidious /etc/invidious/config.yml
rm -f /tmp/invidious-config.yml.tpl

# Invidious reads ./config/config.yml relative to WorkingDirectory; it
# doesn't accept a custom config path. Symlink so secrets stay canonical
# at /etc/invidious/ but the binary finds them where it expects.
runuser -u invidious -- ln -sf /etc/invidious/config.yml /home/invidious/invidious/config/config.yml
REMOTE
log_ok "Phase 4.3a done."

# ─── Phase 4.2: Build Invidious + run migrations ──────────────────────
log_info "Phase 4.2 — build Invidious (Crystal compile, ~10-20 min) + migrate"
ssh_remote <<REMOTE
set -euo pipefail
SRC=/home/invidious/invidious
TAG_MARKER="\$SRC/.built_tag"

# Build only if binary missing or tag changed.
if [ ! -x "\$SRC/invidious" ] || [ "\$(cat \$TAG_MARKER 2>/dev/null || echo none)" != "${INVIDIOUS_TAG}" ]; then
  runuser -u invidious -- bash -c "cd \$SRC && make"
  echo "${INVIDIOUS_TAG}" > "\$TAG_MARKER"
  chown invidious:invidious "\$TAG_MARKER"
fi

# Migrations are idempotent in Invidious.
runuser -u invidious -- bash -c "cd \$SRC && ./invidious --migrate" >/dev/null
REMOTE
log_ok "Phase 4.2 done."

# ─── Phase 4.3b: Install Invidious systemd units + hourly timer ───────
log_info "Phase 4.3b — install systemd units + hourly restart timer"
ssh_push_file "${SCRIPT_DIR}/config/systemd/invidious.service"         /etc/systemd/system/invidious.service
ssh_push_file "${SCRIPT_DIR}/config/systemd/invidious-restart.service" /etc/systemd/system/invidious-restart.service
ssh_push_file "${SCRIPT_DIR}/config/systemd/invidious.timer"           /etc/systemd/system/invidious.timer
ssh_remote <<'REMOTE'
set -euo pipefail
chmod 0644 /etc/systemd/system/invidious.service \
           /etc/systemd/system/invidious-restart.service \
           /etc/systemd/system/invidious.timer
systemctl daemon-reload
systemctl enable --now invidious.service
systemctl enable --now invidious.timer
REMOTE
log_ok "Phase 4.3b done."

# ─── Phase 5.1: Download + extract companion binary ───────────────────
log_info "Phase 5.1 — download companion (${COMPANION_TAG})"
ssh_remote <<REMOTE
set -euo pipefail
COMPANION_DIR=/home/invidious/invidious-companion
TAG_MARKER="\$COMPANION_DIR/.installed_tag"

if [ "\$(cat \$TAG_MARKER 2>/dev/null || echo none)" != "${COMPANION_TAG}" ]; then
  TARBALL=invidious_companion-x86_64-unknown-linux-gnu.tar.gz
  URL=https://github.com/iv-org/invidious-companion/releases/download/${COMPANION_TAG}/\$TARBALL
  rm -rf "\$COMPANION_DIR"
  install -d -m 0755 -o invidious -g invidious "\$COMPANION_DIR"
  wget -q -O /tmp/\$TARBALL "\$URL"
  tar -xzf /tmp/\$TARBALL -C "\$COMPANION_DIR"
  rm -f /tmp/\$TARBALL
  chown -R invidious:invidious "\$COMPANION_DIR"
  echo "${COMPANION_TAG}" > "\$TAG_MARKER"
  chown invidious:invidious "\$TAG_MARKER"
fi

# Bind paths the companion writes to.
install -d -m 0700 -o invidious -g invidious /home/invidious/tmp
install -d -m 0700 -o invidious -g invidious /var/tmp/youtubei.js
REMOTE
log_ok "Phase 5.1 done."

# ─── Phase 5.2: Install companion systemd unit + start ────────────────
log_info "Phase 5.2 — install companion systemd unit + start"
ssh_push_file "${SCRIPT_DIR}/config/systemd/invidious-companion.service" /etc/systemd/system/invidious-companion.service
ssh_remote <<'REMOTE'
set -euo pipefail
chmod 0644 /etc/systemd/system/invidious-companion.service
systemctl daemon-reload
systemctl enable --now invidious-companion.service
REMOTE
log_ok "Phase 5.2 done."

log_ok "Provision complete (Phases 1–5)."
log_info "Next batch will add: cloudflared tunnel + theme deploy pipeline."
