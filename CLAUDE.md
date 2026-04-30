# vidi

> Self-hosted Invidious with a modern glass-aesthetic CSS theme. No fork, no Crystal recompile — a static asset override layered on top of upstream.

## Naming
- **vidi** — this project. The themed Invidious instance.
- **Invidious** — the upstream YouTube alternative front-end (https://github.com/iv-org/invidious).

## Project Info
- **Type:** Personal project
- **License:** MIT
- **GitHub:** nicolasiorio/vidi
- **Architecture:** Static CSS override on top of vanilla Invidious

## Tech Stack
- **Upstream:** Invidious (Crystal, AGPLv3) — installed natively, no Docker. Pinned to `v2.20260207.0`.
- **Companion:** invidious-companion (Deno binary, AGPLv3) — separate systemd service on `localhost:8282`. Required for video playback (replaces deprecated `inv-sig-helper`).
- **Database:** PostgreSQL — Debian default (currently 17 on Trixie)
- **Theme:** Hand-written CSS targeting Invidious's stable BEM-ish class names; modern geometric sans (e.g. Inter)
- **Reverse proxy / TLS:** Cloudflare Tunnel → local Invidious bind
- **Deployment:** Proxmox LXC (Debian 13), systemd services for Invidious + companion + cloudflared, hourly systemd timer to restart Invidious per upstream guidance

## Architecture Overview
```
Internet → Cloudflare edge (TLS) → cloudflared tunnel → Invidious :3000
                                                          ↓
                                                  invidious-companion :8282
                                                          ↓
                                                       Postgres :5432

Theme pipeline:
  vidi.css (this repo)   ──┐
  default.css (upstream) ──┼──> deploy script concats ──> /home/invidious/invidious/assets/css/default.css
                            ↘ on every deploy / upstream release
```

## Components
```
vidi/
  theme/
    vidi.css                  # source-of-truth theme — hand-written
  deploy/
    lxc/                      # planned in feature/lxc-provisioning, built next
      README.md               # operator manual + manual prereqs
      VERSIONS                # pinned versions (Invidious tag, companion tag, host)
      provision.sh            # one-shot bootstrap (idempotent)
      deploy.sh               # theme push (idempotent)
      lib/
        common.sh             # shared bash helpers (ssh, secret gen, idempotency)
        prereq-check.sh       # SSH + cert.pem + zone reachability check
      config/
        invidious-config.yml.tpl
        cloudflared-config.yml.tpl
        systemd/
          invidious.service
          invidious.timer
          invidious-companion.service
  pipeline/                   # NoriCo pipeline artifacts (spec, sprint-plan, reviews)
  planning/                   # feature plans + per-plan artefacts
```

## Key Decisions
- **Pure CSS override, no fork.** Upstream Invidious binary runs unmodified; only the static `default.css` is replaced at deploy time.
- **No template patch.** ECR templates compile into the Crystal binary, so adding a new `<link>` tag would require a fork + recompile. We avoid this by appending to upstream's stylesheet.
- **No Docker.** LXC is already a container; native install matches the karst-prod pattern (systemd + journalctl + cloudflared).
- **Upstream-convention paths.** Source at `/home/invidious/invidious` (matches the systemd unit shipped with Invidious), not `/opt/invidious`.
- **Companion is mandatory.** Since `inv-sig-helper` deprecation, video stream resolution lives in `invidious-companion` (Deno binary, separate service). No companion = no playback.
- **Two secrets, one file.** `secrets.env` (mode 0600 owner invidious) holds Postgres password, HMAC key (32+ hex chars, baked into Invidious config.yml at render), and `SERVER_SECRET_KEY` (exactly 16 chars, used by both Invidious as `invidious_companion_key` and companion as env var). Invidious reads only config.yml; companion reads only env. Same secret value, different loading patterns.
- **Hourly restart timer.** Upstream recommends restarting Invidious "ideally every hour" — we use a systemd `OnUnitActiveSec=1h` timer rather than cron, since timers survive reboots and respect unit deps.
- **Stable selectors only.** Invidious uses BEM-ish class names that have changed only twice in the last 12 months. Theme targets these, never element selectors that might reflow on minor releases.
- **Deploy is idempotent.** Each release: re-fetch upstream `default.css` for the pinned Invidious version, concatenate with `vidi.css`, write atomically to live path, `systemctl restart invidious` (Crystal binary doesn't honour SIGHUP for asset reload). Hash-marker file skips the restart on no-op runs.
- **`provision.sh` ends with `deploy.sh`.** Re-running provision triggers `make`, which restores upstream's `default.css`. Calling deploy as the last step re-applies the theme. Documented contract.
- **Upstream version pinning.** Track a known-good Invidious release tag. Bump deliberately, not on auto-pull.
- **Domain:** `vidi.karst.live` — subdomain of the existing `karst.live` zone in Cloudflare. Zero new DNS infra.

## Deploy

**Repo:** git@github.com:nicolasiorio/vidi.git

### Environments

| Env  | Host                | Platform              | URL              |
|------|---------------------|-----------------------|------------------|
| prod | vidi (10.10.1.44)   | Proxmox LXC on norilab | vidi.karst.live |

Spec at `pipeline/spec.md`. Plan at `planning/lxc-provisioning/plan.md`. Sprint roadmap (3 batches) at `pipeline/sprint-plan.md`. `deploy/lxc/*` scripts written during the `/build` phase.

### Manual prerequisites (set up once before first provision)

1. **SSH key auth to LXC** — `ssh-copy-id root@10.10.1.44` from Mac (LXC is bare Debian 13).
2. **Cloudflare tunnel auth** — `cloudflared tunnel login` on Mac (one-time browser flow, writes `~/.cloudflared/cert.pem`).
3. **Cloudflare zone** — `karst.live` already exists in the operator's Cloudflare account.

## Known Issues
- (None yet — project just scaffolded.)

## Known Constraints
- Invidious upstream releases ~6× per year; each release requires re-fetching `default.css` and re-concatenating.
- CSS override only — anything requiring a new `<link>` tag or `<head>` content would need a fork + Crystal recompile.
- AGPLv3 boundary: this repo is MIT, but we never link/embed Invidious source. The boundary is the static-asset interface.
- Companion mandatory: Invidious without `invidious-companion` runs but cannot play videos (sig-helper deprecation, 2025).
- Crystal compile needs >2.5GB RAM. LXC has 3GB + 512MB host-managed swap (`pct set <CTID> -swap`). Provision aborts if RAM < 2500MB. In-LXC `swapon` is kernel-blocked, so we don't try to create swap from inside the container.
- Hourly restart interrupts viewing for ~2s. Acceptable for personal instance; upstream-recommended.

## Lessons Learned
- (None yet.)
