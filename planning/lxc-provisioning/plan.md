# 📐 Plan: LXC Provisioning + Theme Deploy

**Status:** ✅ Approved
**Date:** 2026-04-30
**Spec:** [pipeline/spec.md](../../pipeline/spec.md)

## 🎯 Overview

Bring the bare Debian 13 LXC at `10.10.1.44` to a fully working themed Invidious instance reachable at `https://vidi.karst.live`, with a repeatable theme deploy pipeline that survives upstream version bumps.

Two scripts, both run from the Mac, both idempotent:
- `provision.sh` — one-shot bootstrap (apt baseline → Crystal → Invidious + companion → cloudflared tunnel)
- `deploy.sh` — theme push (fetch upstream `default.css` for pinned tag → concat with `theme/vidi.css` → atomic write → reload)

## ✅ Requirements Covered

All FR-001 through FR-008 from spec, plus FR-009 added per round-3 review:

| Req | Phase covering it |
|-----|-------------------|
| FR-001 LXC bootstrap | Phase 2 |
| FR-002 PostgreSQL | Phase 3 |
| FR-003 Invidious install | Phase 4 |
| FR-004 Invidious config + secrets | Phase 4 |
| FR-005 Cloudflared tunnel | Phase 6 |
| FR-006 Theme deploy pipeline | Phase 7 |
| FR-007 Idempotency & safety | Cross-cutting (every phase) + Phase 8 |
| FR-008 Manual prereqs | Phase 1 (`prereq-check.sh` + README) |
| FR-009 invidious-companion (added in /roadmap) | Phase 5 |

## 🏗️ Technical Design

See [`artefacts/architecture-notes.md`](artefacts/architecture-notes.md) for the end-state diagram and [`artefacts/file-map.md`](artefacts/file-map.md) for the file inventory. Summary here:

### Solution Architecture

- **Control plane:** Mac running bash. SSH into `10.10.1.44` for every operation. No agent on LXC.
- **Compute plane:** Single Debian 13 LXC. All services run as systemd units. Postgres + Invidious + companion bind localhost only. Cloudflared is the sole ingress.
- **Data flow at request time:** browser → Cloudflare edge (TLS) → cloudflared tunnel (outbound from LXC) → `localhost:3000` (Invidious) → `localhost:8282` (companion, for video stream resolution) → YouTube.

### Repo Layout

```
deploy/lxc/
├── README.md                   # operator guide + manual prereqs
├── VERSIONS                    # pinned versions in one place
├── provision.sh                # one-shot bootstrap (idempotent)
├── deploy.sh                   # theme push (idempotent)
├── lib/
│   ├── common.sh               # ssh wrappers, idempotency helpers, secret gen
│   └── prereq-check.sh         # validates SSH + cert.pem + zone reachable
└── config/
    ├── invidious-config.yml.tpl
    ├── cloudflared-config.yml.tpl
    └── systemd/
        ├── invidious.service
        ├── invidious.timer
        └── invidious-companion.service
```

### Data / Config Models

All template variables resolved at apply time via `envsubst`. Source values come from:
- `VERSIONS` (committed) — pinned versions, host, user
- `/etc/invidious/secrets.env` on LXC (generated once, never rotated) — `POSTGRES_PASSWORD`, `HMAC_KEY`, `COMPANION_KEY`
- `~/.cloudflared/cert.pem` on Mac (manual prereq) — Cloudflare account auth for tunnel CRUD

### Development Resources

| Tool | Where | Why |
|------|-------|-----|
| `bash` | Mac + LXC | Scripts |
| `ssh` | Mac | Remote command execution |
| `envsubst` (gettext-base) | Both | Template substitution |
| `jq` | Mac | Parse `cloudflared tunnel list --output json` |
| `cloudflared` CLI | Mac (manual install via `brew`) and LXC (apt) | Tunnel CRUD on Mac, daemon on LXC |
| `pwgen` | LXC (apt) | Secret generation per upstream guidance |
| Crystal toolchain | LXC | Build Invidious |
| PostgreSQL 17 | LXC | Invidious DB |

No new third-party libraries added to the repo. Scripts are pure bash + system tools.

## 💡 Assumptions

1. **LXC has internet egress.** All apt installs, git clones, and tunnel registration go through the LXC's network.
2. **LXC has root or passwordless sudo via SSH key.** Spec said "not set up" but Nicolas will set up SSH key auth before first run (`prereq-check.sh` verifies).
3. **`karst.live` zone exists in Cloudflare.** `cloudflared tunnel route dns` requires this. We don't create zones programmatically.
4. **Mac has `cloudflared` CLI installed and `cloudflared tunnel login` has been run once.** Documented prereq.
5. **No existing Invidious or Postgres state on the LXC.** First-run assumption. Idempotency makes re-runs safe but we don't try to migrate from a partial install.
6. **Postgres 17 + Invidious is compatible.** Invidious uses standard SQL (no version-specific features). Confirmed by community reports.
7. **systemd hardening directives work in this LXC.** Modern unprivileged Debian LXCs support `ProtectSystem=strict`, `PrivateTmp`, etc. We start with full hardening and soften only if it breaks.
8. **Compiling Crystal binary requires ~2.5GB RAM, but LXC has 2GB.** Provision adds a 2GB swap file before `make`.
9. **`crystal-lang.org/install.sh` supports Debian 13** (or its OBS source has a Trixie target). Fallback: pin Bookworm packages explicitly.

## 🔨 Implementation Phases

**Difficulty key:** 1-3 Low (boilerplate), 4-7 Medium (real logic), 8-10 High (gnarly).

### Phase 1: Foundation — repo scaffold + helpers + prereq check (Diff: 6)

- **Task 1.1: Create repo skeleton** (Diff: 2)
  - Files: `deploy/lxc/{README.md,VERSIONS,provision.sh,deploy.sh}` (placeholders), `deploy/lxc/lib/{common.sh,prereq-check.sh}`, `deploy/lxc/config/{invidious-config.yml.tpl,cloudflared-config.yml.tpl,systemd/}`
  - 💡 Why: One-time scaffolding so subsequent tasks have a place to write code. Empty placeholders with `set -euo pipefail` headers.

- **Task 1.2: Write `lib/common.sh`** (Diff: 4)
  - Files: `deploy/lxc/lib/common.sh`
  - 💡 Why: All scripts need the same helpers. Centralize them once: `ssh_run "cmd"` (runs on LXC, exits non-zero on failure), `ssh_run_quiet`, `gen_secret <length>` (uses `openssl rand -hex`), `read_versions` (sources `VERSIONS`), `log_info` / `log_err` (colored output), `confirm "prompt"` for destructive actions.

- **Task 1.3: Write `lib/prereq-check.sh`** (Diff: 3)
  - Files: `deploy/lxc/lib/prereq-check.sh`
  - 💡 Why: Fail fast at start of every script run. Checks: SSH connects to `$LXC_HOST`, sudo works, `cloudflared` CLI on Mac, `~/.cloudflared/cert.pem` exists and is mode 0600, `cloudflared tunnel list` works (proves cert.pem is valid), DNS zone `karst.live` shows up in `cloudflared tunnel route dns --help` output (proxy: zone is reachable).

- **Task 1.4: Write `deploy/lxc/README.md`** (Diff: 2)
  - Files: `deploy/lxc/README.md`
  - 💡 Why: Manual prereq list with copy-pasteable commands. Documents the contract for FR-008.

### Phase 2: System bootstrap (Diff: 5)

- **Task 2.1: apt baseline + locale + timezone + swap** (Diff: 3)
  - Files: `deploy/lxc/provision.sh` (section)
  - 💡 Why: First section of provision.sh. `apt update && apt full-upgrade -y`, set locale (`locale-gen en_US.UTF-8`), timezone (`timedatectl set-timezone UTC`), create 2GB `/swapfile` if not present (Crystal needs >2GB RAM to compile).

- **Task 2.2: Install build deps + create invidious user** (Diff: 2)
  - Files: `deploy/lxc/provision.sh` (section)
  - 💡 Why: One apt install for everything: `libssl-dev libxml2-dev libyaml-dev libgmp-dev libreadline-dev librsvg2-bin libsqlite3-dev zlib1g-dev libpcre3-dev libevent-dev fonts-open-sans pwgen git make gettext-base jq`. User: `useradd -m -s /bin/bash invidious` (matches upstream convention; locked password).

### Phase 3: PostgreSQL (Diff: 4)

- **Task 3.1: Install Postgres + secrets bootstrap** (Diff: 4)
  - Files: `deploy/lxc/provision.sh` (section), `/etc/invidious/secrets.env` (created on LXC at runtime)
  - 💡 Why: `apt install postgresql` (Debian 13 → PG17). Generate `secrets.env` once (`POSTGRES_PASSWORD`, `HMAC_KEY` 32 hex, `COMPANION_KEY` 16 chars exactly per upstream constraint). Mode 0600, owner `invidious`. Create role `invidious` with that password, db `invidious` owned by it. Postgres binds localhost by default on Debian.
  - Dependencies: Phase 2

### Phase 4: Invidious build + config + systemd (Diff: 8)

- **Task 4.1: Install Crystal + clone Invidious at pinned tag** (Diff: 3)
  - Files: `deploy/lxc/provision.sh` (section)
  - 💡 Why: `curl -fsSL https://crystal-lang.org/install.sh | sudo bash` (idempotent — script handles existing source). Clone `github.com/iv-org/invidious` to `/home/invidious/invidious`, checkout `$INVIDIOUS_TAG`. On re-run with same tag: no-op via `git fetch --tags && git checkout $TAG`.
  - Risk: OBS repo Trixie support — fallback uses Bookworm packages.

- **Task 4.2: Build Invidious + run migrations** (Diff: 3)
  - Files: `deploy/lxc/provision.sh` (section)
  - 💡 Why: `sudo -u invidious make` (10-20 min). Then `sudo -u invidious ./invidious --migrate` to apply DB schema. Detect already-built binary by mtime vs source dir — skip rebuild if same tag.

- **Task 4.3: Render config.yml + install systemd unit + timer** (Diff: 4)
  - Files: `deploy/lxc/config/invidious-config.yml.tpl`, `deploy/lxc/config/systemd/invidious.service`, `deploy/lxc/config/systemd/invidious.timer`, `deploy/lxc/provision.sh` (section)
  - 💡 Why: Template covers `db.password`, `hmac_key`, `invidious_companion.private_url` (`http://127.0.0.1:8282/companion`), `invidious_companion_key`, `domain: vidi.karst.live`, `https_only: true`, `external_port: 443`, `registration_enabled: true`. Render via `envsubst` (sourcing `/etc/invidious/secrets.env`) → `/etc/invidious/config.yml` (mode 0640, owner invidious — secrets are baked into config.yml itself; Invidious does not read env vars). systemd unit copied from upstream verbatim (already correct: `User=invidious`, `WorkingDirectory=/home/invidious/invidious`, `Restart=always`, `RestartSec=2s`). Timer unit: `OnUnitActiveSec=1h`, `Unit=invidious.service`, `Persistent=true`.
  - Dependencies: Tasks 4.1, 4.2, 3.1

### Phase 5: invidious-companion (Diff: 5)

- **Task 5.1: Download + extract companion binary** (Diff: 2)
  - Files: `deploy/lxc/provision.sh` (section)
  - 💡 Why: `wget https://github.com/iv-org/invidious-companion/releases/download/$COMPANION_TAG/invidious_companion-x86_64-unknown-linux-gnu.tar.gz`, extract to `/home/invidious/invidious-companion/`, owner invidious. Idempotent: skip if binary exists and tag matches a pin file we drop alongside.

- **Task 5.2: Install companion systemd unit + secret env** (Diff: 3)
  - Files: `deploy/lxc/config/systemd/invidious-companion.service`, `deploy/lxc/provision.sh` (section)
  - 💡 Why: Copy upstream unit; replace its hardcoded `Environment=SERVER_SECRET_KEY=CHANGE_ME` with `EnvironmentFile=/etc/invidious/secrets.env` (which contains the line `SERVER_SECRET_KEY=...` written during Phase 3 — same value as Invidious's `invidious_companion_key`). Create `/home/invidious/tmp` and `/var/tmp/youtubei.js` for bind paths. `daemon-reload`, `enable --now`. Verify with `curl -fs http://127.0.0.1:8282` (200 or 404 — anything but connection refused proves it's listening).
  - Dependencies: Phase 4 (config has matching companion key)

### Phase 6: Cloudflared tunnel (Diff: 7)

- **Task 6.1: Create tunnel + DNS route from Mac** (Diff: 4)
  - Files: `deploy/lxc/provision.sh` (section, runs locally before SSH'ing)
  - 💡 Why: Tunnel CRUD requires `cert.pem` which lives on the Mac. Idempotently: `cloudflared tunnel list --output json | jq -e '.[] | select(.name=="vidi")'` → reuse, else `cloudflared tunnel create vidi` (writes credentials to `~/.cloudflared/<UUID>.json`). Then `cloudflared tunnel route dns vidi vidi.karst.live` (idempotent — Cloudflare dedupes). Capture UUID for next step.

- **Task 6.2: Install cloudflared on LXC + push credentials + config** (Diff: 3)
  - Files: `deploy/lxc/config/cloudflared-config.yml.tpl`, `deploy/lxc/provision.sh` (section)
  - 💡 Why: Add Cloudflare apt source (try `trixie`, fall back to `bookworm` — same .deb works on both). `apt install cloudflared`. `scp ~/.cloudflared/<UUID>.json root@LXC:/etc/cloudflared/vidi.json` (mode 0600). Render `config.yml.tpl` with tunnel UUID + hostname → `/etc/cloudflared/config.yml`. `systemctl enable --now cloudflared` (the apt package ships its own unit).
  - Dependencies: Task 6.1

### Phase 7: Theme deploy pipeline (Diff: 5)

- **Task 7.1: Write `deploy.sh`** (Diff: 5)
  - Files: `deploy/lxc/deploy.sh`
  - 💡 Why: (1) Sources `VERSIONS` for `INVIDIOUS_TAG`. (2) Fetches upstream CSS via `gh api repos/iv-org/invidious/contents/assets/css/default.css?ref=$INVIDIOUS_TAG`. (3) Reads local `theme/vidi.css`. (4) Concatenates: upstream first, theme appended (later rules win). Hashes the output. If hash matches the marker file at `/home/invidious/invidious/assets/css/.vidi.hash` on the LXC → skip (idempotent). (5) On first run, backs up upstream file to `default.css.upstream.bak`. (6) Pipes the new content to LXC via SSH, written atomically (`> /tmp/default.css.new && mv -f /tmp/default.css.new /home/invidious/invidious/assets/css/default.css`). (7) Writes new hash. (8) `systemctl restart invidious` (Crystal binary doesn't honor SIGHUP for asset reload — restart is the supported path; ~2s).
  - Dependencies: Phases 1-6 must have produced a working install. `provision.sh` must call `deploy.sh` as its final step so `make` rebuilds don't leave the upstream CSS in place.

### Phase 8: Idempotency hardening + manual test pass (Diff: 4)

- **Task 8.1: Re-run provision and verify no-op** (Diff: 2)
  - 💡 Why: Run `./provision.sh` a second time on the already-provisioned LXC. Should exit 0 with no service restarts beyond the deploy.sh-triggered one (which is also idempotent). Catch any "always-run" steps that should be guarded.

- **Task 8.2: Cosmetic theme tweak deploy** (Diff: 2)
  - 💡 Why: Edit `theme/vidi.css` to add a single `body { background: red }`. Run `./deploy.sh`. Reload `vidi.karst.live` in browser — should see red. Run `./deploy.sh` again with no changes — exits without restarting Invidious.

## 🧪 Testing Strategy

This is infrastructure — no unit tests. Validation is end-to-end manual:

| Layer | Test |
|-------|------|
| Postgres | `ssh root@10.10.1.44 'sudo -u postgres psql -c "\du invidious"'` shows role exists |
| Invidious | `ssh root@10.10.1.44 'curl -sf http://127.0.0.1:3000/api/v1/stats'` returns JSON |
| Companion | `ssh root@10.10.1.44 'curl -sIf http://127.0.0.1:8282'` returns any 2xx/3xx/4xx (proves listening) |
| Tunnel ingress | `curl -sIf https://vidi.karst.live` returns `200 OK` with valid TLS |
| Playback | Open `https://vidi.karst.live`, watch any video for 30s — proves companion working |
| Multi-user | Sign up, log in, log out, sign up second user — all succeed |
| Theme override | `curl -s https://vidi.karst.live/css/default.css \| tail -20` shows vidi.css content after upstream |
| Idempotency | Re-run provision → exit 0, no unexpected restarts |
| Hourly restart | Wait or `systemctl start invidious.timer; sleep 5; systemctl list-timers \| grep invidious` |

## ⚠️ Risks and Mitigations

| Risk | Severity | Mitigation |
|------|----------|------------|
| Crystal install fails on Trixie via OBS | 🟠 Major | Fallback path: explicit Bookworm sources.list. Test in Phase 4.1; if it fails, edit fallback into the script. |
| 2GB LXC RAM insufficient to compile Invidious | 🟠 Major | Provision adds 2GB swap *before* `make`. Documented in README. |
| Cloudflared apt repo lacks Trixie suite | 🟡 Minor | Try `trixie` first, fall back to `bookworm`. Bookworm .deb runs fine on Trixie (glibc-compatible). |
| `make` rebuild on re-provision clobbers theme | 🟠 Major | `provision.sh` ends with `./deploy.sh`. Documented in README and architecture-notes. |
| systemd hardening fails in LXC namespace | 🟡 Minor | Start with full hardening; document soft-fail strategy in `architecture-notes.md`. If a directive fails, drop it from the unit file (not silently ignore). |
| `cloudflared tunnel create` requires `cert.pem` and Nicolas hasn't done it yet | 🔴 Critical | `prereq-check.sh` exits with explicit message + setup command before any LXC mutation. |
| `secrets.env` accidentally committed | 🔴 Critical | Lives only on LXC, never on Mac. `.gitignore` already covers `.env`. |
| Tunnel UUID collision on rerun | 🟡 Minor | Idempotent check via `cloudflared tunnel list --output json`. Reuse if exists. |
| Companion key wrong length (must be exactly 16) | 🟠 Major | `gen_secret 16` enforces. Validated by upstream — Invidious refuses to start if length wrong, surfaces as journald error during 4.3 verify. |
| Theme deploy applied while Invidious is mid-restart from hourly timer | 🟡 Minor | `systemctl restart invidious` is sequential — one restart at a time. Worst case: deploy waits ~2s. Acceptable. |
| Upstream changes asset path or build flow on next version bump | 🟠 Major | Version bump = re-test deploy. Mitigation captured in spec out-of-scope ("auto-bumping is manual"). |

## 🚫 Out of Scope

(All carried from spec, plus reaffirmed here.)
- Backup / DR for Postgres data
- Automated rollback (manual: revert tag, re-provision)
- Monitoring beyond journald
- CI/CD (deploy is manual `./deploy.sh`)
- Theme CSS content (separate spec)
- Multi-instance / HA
- SMTP / Invidious email features
- Auto-bumping upstream version

## 🤝 Context Handover

_None yet — plan is fresh._
