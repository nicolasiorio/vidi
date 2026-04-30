# 📋 Spec: LXC Provisioning + Theme Deploy

**Status:** ✅ Approved
**Date:** 2026-04-30

## 🎯 Overview
- **Problem:** Empty Debian 13 LXC needs to become a working themed Invidious instance at `vidi.karst.live`, with a repeatable pipeline for theme changes and upstream version bumps.
- **Target User:** Nicolas (operator). End viewers see only the result.
- **Platforms:** Server — Debian 13 LXC on Proxmox (`10.10.1.44`). Control plane — macOS (scripts run via SSH).

## ✅ Requirements

### FR-001: LXC bootstrap
- **Description:** Bring bare Debian 13 LXC to baseline (apt updated, locale, timezone, build deps, `invidious` system user).
- **Error Handling:** 🚨 Alert (exits non-zero with clear message)
- **Acceptance Criteria:**
  - [ ] apt index up to date, system upgraded
  - [ ] Locale `en_US.UTF-8`, timezone `UTC`
  - [ ] Crystal toolchain + Invidious build deps installed (libssl, libxml2, libyaml, libgmp, libreadline, libsqlite3, zlib, libpcre3, git)
  - [ ] System user `invidious` exists, no shell login
  - [ ] Re-running on provisioned host is a no-op

### FR-002: PostgreSQL install + DB setup
- **Description:** Install Postgres, create role + database, store password in secrets file.
- **Error Handling:** 🚨 Alert
- **Acceptance Criteria:**
  - [ ] postgresql installed, service enabled, running, bound to localhost only
  - [ ] Role `invidious` exists with random-generated password
  - [ ] Database `invidious` exists, owned by `invidious` role
  - [ ] Password written to `/etc/invidious/secrets.env` (mode 0600, owner `invidious`)
  - [ ] Re-run preserves existing DB + password

### FR-003: Invidious install at pinned version
- **Description:** Clone Invidious at tag `v2.20260207.0`, build, install systemd unit.
- **Error Handling:** 🚨 Alert
- **Acceptance Criteria:**
  - [ ] Source at `/opt/invidious` checked out at pinned tag
  - [ ] Binary built via `shards build --release --production`
  - [ ] `invidious.service` installed, enabled, running as `invidious` user
  - [ ] Service binds `127.0.0.1:3000` only
  - [ ] `journalctl -u invidious` shows clean startup
  - [ ] Same-tag re-run = no-op; bumped-tag re-run rebuilds and restarts

### FR-004: Invidious config (multi-user, secrets)
- **Description:** Generate HMAC key, write `config.yml` with sign-ups enabled.
- **Error Handling:** 🚨 Alert
- **Acceptance Criteria:**
  - [ ] `/etc/invidious/config.yml` exists, mode 0640, owner `invidious`
  - [ ] HMAC key (32+ random bytes) generated on first run, persisted, never rotated
  - [ ] DB connection uses creds from `secrets.env`
  - [ ] `registration_enabled: true`, `https_only: true`, `domain: vidi.karst.live`
  - [ ] No secrets committed to repo

### FR-005: Cloudflared tunnel
- **Description:** Install cloudflared, create tunnel `vidi`, route DNS, install systemd unit pointing at `localhost:3000`.
- **Error Handling:** 🚨 Alert
- **Acceptance Criteria:**
  - [ ] cloudflared installed from Cloudflare apt repo
  - [ ] Tunnel `vidi` created; credentials JSON at `/etc/cloudflared/vidi.json` (0600, root)
  - [ ] DNS record `vidi.karst.live` → tunnel UUID in `karst.live` zone
  - [ ] `/etc/cloudflared/config.yml` routes hostname → `http://localhost:3000`
  - [ ] `cloudflared.service` enabled, running
  - [ ] `https://vidi.karst.live` returns Invidious homepage with valid TLS
  - [ ] Re-run reuses existing tunnel

### FR-006: Theme deploy pipeline
- **Description:** `deploy.sh` fetches upstream `default.css` for the pinned Invidious version, concatenates with `theme/vidi.css`, writes to live path, reloads Invidious.
- **Error Handling:** 🚨 Alert (fail fast on missing inputs)
- **Acceptance Criteria:**
  - [ ] Fetches `default.css` from `iv-org/invidious` at pinned tag (not `main`)
  - [ ] Order: upstream CSS first, then `theme/vidi.css` (overrides win)
  - [ ] Output written atomically (temp file + rename) to `/opt/invidious/assets/css/default.css`
  - [ ] Original upstream CSS backed up to `.upstream.bak` on first deploy
  - [ ] `systemctl reload invidious` after write
  - [ ] mtime change forces browser cache bust
  - [ ] Re-running with same inputs is idempotent
  - [ ] Bumping pinned tag re-fetches matching upstream CSS

### FR-007: Idempotency & safety
- **Acceptance Criteria:**
  - [ ] `provision.sh` detects existing components and skips
  - [ ] Secrets generated only on first run
  - [ ] No script wipes data without explicit `--reset` flag (not implemented in v1)

### FR-008: Manual prerequisites documented
- **Acceptance Criteria:**
  - [ ] Prereqs listed in `deploy/lxc/README.md`: SSH key auth to 10.10.1.44, `cloudflared tunnel login` with `~/.cloudflared/cert.pem` present, `karst.live` zone in Cloudflare
  - [ ] Each has copy-pasteable command
  - [ ] `provision.sh` checks prereqs at start, exits with clear message if missing

## ⚙️ Non-Functional Requirements
- **Performance:** Provision < 30 min on 2 vCPU / 2GB LXC (Crystal compile dominates). Deploy < 30s.
- **Security:** All secrets `0600` in `/etc/invidious/`, never committed. Postgres + Invidious bound to localhost. cloudflared the only ingress.
- **Reliability:** `Restart=on-failure` for both systemd services.
- **Observability:** journald only.
- **Idempotency:** Every script re-runnable safely.

## 📊 Data Requirements
- **Postgres data:** `/var/lib/postgresql/14/main/`. Backups out of scope.
- **Invidious config + secrets:** `/etc/invidious/{config.yml,secrets.env}`
- **Cloudflared credentials:** `/etc/cloudflared/{vidi.json,config.yml}`
- **Theme source (repo):** `theme/vidi.css`
- **Theme output (server):** `/opt/invidious/assets/css/default.css`

## 🔗 Dependencies

| Dependency | Why | License | Compatible? |
|---|---|---|---|
| Invidious `v2.20260207.0` | The product | AGPLv3 | ✓ — static-asset boundary, no linking |
| PostgreSQL 14 | Invidious DB | PostgreSQL License | ✓ |
| Crystal toolchain | Build Invidious | Apache 2.0 | ✓ |
| cloudflared | TLS + ingress | Apache 2.0 | ✓ |

No third-party libs added to this repo. All scripts are bash + system tools.

## 🚫 Out of Scope
- Backups / DR (future feature)
- Multi-instance / HA
- Monitoring / alerting beyond journald
- CI/CD (deploy is manual `./deploy.sh`)
- Theme CSS content itself — `theme/vidi.css` can ship empty; styling is a separate spec
- Auto-bumping upstream version (deliberate, manual edit of pinned tag)
- Rollback automation
- Email / SMTP inside Invidious
