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
- **Upstream:** Invidious (Crystal, AGPLv3) — installed natively, no Docker
- **Database:** PostgreSQL 14 (required by Invidious)
- **Theme:** Hand-written CSS targeting Invidious's stable BEM-ish class names; modern geometric sans (e.g. Inter)
- **Reverse proxy / TLS:** Cloudflare Tunnel → local Invidious bind
- **Deployment:** Proxmox LXC (Debian 13), systemd service for Invidious, systemd service for cloudflared

## Architecture Overview
```
Internet → Cloudflare edge (TLS) → cloudflared tunnel → Invidious :3000
                                                          ↓
                                                       Postgres :5432

Theme pipeline:
  vidi.css (this repo)   ──┐
  default.css (upstream) ──┼──> deploy script concats ──> /opt/invidious/assets/css/default.css
                            ↘ on every deploy / upstream release
```

## Components
```
vidi/
  theme/
    vidi.css         # source-of-truth theme — hand-written
  deploy/
    lxc/             # provision.sh, cloudflared-setup.sh, deploy.sh (TBD in build phase)
  pipeline/          # NoriCo pipeline artifacts (specs, reviews)
  planning/          # feature plans
```

## Key Decisions
- **Pure CSS override, no fork.** Upstream Invidious binary runs unmodified; only the static `default.css` is replaced at deploy time.
- **No template patch.** ECR templates compile into the Crystal binary, so adding a new `<link>` tag would require a fork + recompile. We avoid this by appending to upstream's stylesheet.
- **No Docker.** LXC is already a container; native install matches the karst-prod pattern (systemd + journalctl + cloudflared).
- **Stable selectors only.** Invidious uses BEM-ish class names that have changed only twice in the last 12 months. Theme targets these, never element selectors that might reflow on minor releases.
- **Deploy is idempotent.** Each release: re-fetch upstream `default.css` for the pinned Invidious version, concatenate with `vidi.css`, write to live path, `systemctl reload invidious`.
- **Upstream version pinning.** Track a known-good Invidious release tag. Bump deliberately, not on auto-pull.
- **Domain:** `vidi.karst.live` — subdomain of the existing `karst.live` zone in Cloudflare. Zero new DNS infra.

## Deploy

**Repo:** git@github.com:nicolasiorio/vidi.git

### Environments

| Env  | Host           | Platform              | URL              |
|------|----------------|-----------------------|------------------|
| prod | vidi (TBD ID)  | Proxmox LXC on norilab | vidi.karst.live |

Provision details and `deploy/lxc/*` scripts are written during the `/build` phase.

## Known Issues
- (None yet — project just scaffolded.)

## Known Constraints
- Invidious upstream releases ~6× per year; each release requires re-fetching `default.css` and re-concatenating.
- CSS override only — anything requiring a new `<link>` tag or `<head>` content would need a fork + Crystal recompile.
- AGPLv3 boundary: this repo is MIT, but we never link/embed Invidious source. The boundary is the static-asset interface.

## Lessons Learned
- (None yet.)
