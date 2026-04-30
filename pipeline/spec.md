# 📋 Spec: LXC Provisioning + Theme Deploy

**Status:** ✅ Approved
**Date:** 2026-04-30
**Amended:** 2026-04-30 via `/roadmap` research — added FR-009 (invidious-companion), corrected install path to `/home/invidious/invidious` (upstream convention), updated Postgres to Debian-default version, clarified two-secret model, switched to upstream-recommended hourly restart timer.

## 🎯 Overview
- **Problem:** Empty Debian 13 LXC needs to become a working themed Invidious instance at `vidi.karst.live`, with a repeatable pipeline for theme changes and upstream version bumps.
- **Target User:** Nicolas (operator). End viewers see only the result.
- **Platforms:** Server — Debian 13 LXC on Proxmox (`10.10.1.44`). Control plane — macOS (scripts run via SSH).

## ✅ Requirements

### FR-001: LXC bootstrap
- **Description:** Bring bare Debian 13 LXC to baseline (apt updated, locale, timezone, RAM-floor check, build deps, `invidious` system user).
- **Error Handling:** 🚨 Alert (exits non-zero with clear message)
- **Acceptance Criteria:**
  - [ ] apt index up to date, system upgraded
  - [ ] Locale `en_US.UTF-8`, timezone `UTC`
  - [ ] RAM floor check: provision aborts if LXC has <2500 MB RAM (Crystal compile peaks ~2.5GB; LXC swap is host-managed via `pct set <CTID> -swap N`, can't be created from inside the container)
  - [ ] Crystal toolchain + Invidious build deps installed (libssl, libxml2, libyaml, libgmp, libreadline, libsqlite3, zlib, libpcre2, libevent, librsvg2-bin, fonts-open-sans, pwgen, git, make, gettext-base, jq)
  - [ ] System user `invidious` exists with home dir `/home/invidious`, locked password
  - [ ] Re-running on provisioned host is a no-op

### FR-002: PostgreSQL install + DB setup
- **Description:** Install Postgres (Debian default — PG17 on Trixie), create role + database, store password in secrets file.
- **Error Handling:** 🚨 Alert
- **Acceptance Criteria:**
  - [ ] postgresql installed, service enabled, running, bound to localhost only
  - [ ] Role `invidious` exists with random-generated password
  - [ ] Database `invidious` exists, owned by `invidious` role
  - [ ] Password written to `/etc/invidious/secrets.env` (mode 0600, owner `invidious`)
  - [ ] Re-run preserves existing DB + password

### FR-003: Invidious install at pinned version
- **Description:** Clone Invidious at tag `v2.20260207.0`, build via upstream Makefile, install systemd unit + hourly restart timer.
- **Error Handling:** 🚨 Alert
- **Acceptance Criteria:**
  - [ ] Source at `/home/invidious/invidious` checked out at pinned tag (upstream convention)
  - [ ] Binary built via `make` (which wraps `shards build --release --production`)
  - [ ] DB schema applied via `./invidious --migrate`
  - [ ] `invidious.service` installed, enabled, running as `invidious` user
  - [ ] `invidious.timer` enabled — restarts service every hour (`OnUnitActiveSec=1h`) per upstream guidance
  - [ ] Service binds `127.0.0.1:3000` only
  - [ ] `journalctl -u invidious` shows clean startup
  - [ ] Same-tag re-run = no-op; bumped-tag re-run rebuilds and restarts

### FR-004: Invidious config (multi-user, secrets)
- **Description:** Generate two secrets (HMAC + companion key), write `config.yml` with sign-ups enabled and companion endpoint.
- **Error Handling:** 🚨 Alert
- **Acceptance Criteria:**
  - [ ] `/etc/invidious/config.yml` exists, mode 0640, owner `invidious` (secrets baked in — Invidious does not read env vars)
  - [ ] `hmac_key` (32+ random hex chars) generated on first run, persisted, never rotated
  - [ ] `invidious_companion_key` (exactly 16 chars per upstream constraint) generated on first run, persisted, never rotated
  - [ ] `invidious_companion: [{ private_url: "http://127.0.0.1:8282/companion" }]` configured
  - [ ] DB connection uses creds from `secrets.env`
  - [ ] `registration_enabled: true`, `https_only: true`, `domain: vidi.karst.live`, `external_port: 443`
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
- **Description:** `deploy.sh` fetches upstream `default.css` for the pinned Invidious version, concatenates with `theme/vidi.css`, writes to live path, restarts Invidious. `provision.sh` ends by invoking `deploy.sh` so re-provisioning (which re-runs `make`) doesn't leave the upstream CSS in place.
- **Error Handling:** 🚨 Alert (fail fast on missing inputs)
- **Acceptance Criteria:**
  - [ ] Fetches `default.css` from `iv-org/invidious` at pinned tag (not `main`)
  - [ ] Order: upstream CSS first, then `theme/vidi.css` (overrides win)
  - [ ] Output written atomically (temp file + rename) to `/home/invidious/invidious/assets/css/default.css`
  - [ ] Original upstream CSS backed up to `.upstream.bak` on first deploy
  - [ ] `systemctl restart invidious` after write (Crystal binary doesn't honour SIGHUP for asset reload)
  - [ ] mtime change forces browser cache bust
  - [ ] Re-running with same inputs is idempotent (hash-marker skip)
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

### FR-009: invidious-companion service
- **Description:** Install `invidious-companion` (Deno binary) as a separate systemd service. Mandatory for video playback since `inv-sig-helper` was deprecated. Communicates with Invidious internally over `localhost:8282`.
- **Error Handling:** 🚨 Alert
- **Acceptance Criteria:**
  - [ ] Companion binary extracted to `/home/invidious/invidious-companion/` (owner `invidious`)
  - [ ] Pinned to release tag (`COMPANION_TAG` in `VERSIONS`); same-tag re-run is a no-op
  - [ ] `invidious-companion.service` installed, enabled, running as `invidious` user
  - [ ] Service binds `127.0.0.1:8282` only
  - [ ] `SERVER_SECRET_KEY` env loaded from `/etc/invidious/secrets.env` via `EnvironmentFile=`; matches `invidious_companion_key` in `config.yml`
  - [ ] Bind paths exist and writable: `/home/invidious/tmp`, `/var/tmp/youtubei.js`
  - [ ] `journalctl -u invidious-companion` shows clean startup
  - [ ] End-to-end playback works (proves Invidious ↔ companion handshake)

## ⚙️ Non-Functional Requirements
- **Performance:** Provision < 30 min on 2 vCPU / 3GB LXC + host-managed swap (Crystal compile dominates). Deploy < 30s.
- **Security:** All secrets `0600` in `/etc/invidious/`, never committed. Postgres, Invidious, and companion all bind localhost. cloudflared the only ingress.
- **Reliability:** `Restart=always` with `RestartSec=2s` for invidious, invidious-companion, and cloudflared (matches upstream units). Hourly restart timer for Invidious per upstream guidance.
- **Observability:** journald only.
- **Idempotency:** Every script re-runnable safely.

## 📊 Data Requirements
- **Postgres data:** `/var/lib/postgresql/17/main/` (Debian 13 default). Backups out of scope.
- **Invidious config + secrets:** `/etc/invidious/{config.yml,secrets.env}`
- **Invidious source + binary:** `/home/invidious/invidious/`
- **Companion binary:** `/home/invidious/invidious-companion/`
- **Companion runtime dirs:** `/home/invidious/tmp`, `/var/tmp/youtubei.js`
- **Cloudflared credentials:** `/etc/cloudflared/{vidi.json,config.yml}`
- **Theme source (repo):** `theme/vidi.css`
- **Theme output (server):** `/home/invidious/invidious/assets/css/default.css`

## 🔗 Dependencies

| Dependency | Why | License | Compatible? |
|---|---|---|---|
| Invidious `v2.20260207.0` | The product | AGPLv3 | ✓ — static-asset boundary, no linking |
| invidious-companion (`release-master`) | Required for video playback (replaces inv-sig-helper) | AGPLv3 | ✓ — separate process, no linking |
| PostgreSQL (Debian default — currently 17) | Invidious DB | PostgreSQL License | ✓ |
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
