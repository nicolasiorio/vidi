# 🗂️ File Map — LXC Provisioning + Theme Deploy

This is a greenfield infra feature. There is no existing code to reuse — the file map below documents (a) the upstream files we depend on as contracts, and (b) the new files we will create in this repo.

## 📤 Upstream contracts (read-only references)

| Path | Source | Purpose | Why we depend on it |
|------|--------|---------|---------------------|
| `iv-org/invidious@v2.20260207.0/invidious.service` | upstream | systemd unit shipped with Invidious source | We override it (add `EnvironmentFile=/etc/invidious/secrets.env`, `RestartSec=2s` already present, hardening) |
| `iv-org/invidious@v2.20260207.0/Makefile` | upstream | wraps `shards build --release --production` | Called as `make` in `/home/invidious/invidious` |
| `iv-org/invidious@v2.20260207.0/config/config.example.yml` | upstream | reference config | Our config.yml is a minimal subset — only DB, hmac_key, companion config, domain, https_only, registration_enabled |
| `iv-org/invidious@v2.20260207.0/assets/css/default.css` | upstream | served at `/css/default.css` | `deploy.sh` fetches this and concatenates with `theme/vidi.css` |
| `iv-org/invidious-companion@release-master/invidious-companion.service` | upstream | systemd unit for companion | We override env (`SERVER_SECRET_KEY`) and bind paths |
| `iv-org/invidious-companion releases` | upstream | `invidious_companion-x86_64-unknown-linux-gnu.tar.gz` | Downloaded and extracted to `/home/invidious/invidious-companion/` |
| `crystal-lang.org/install.sh` | crystal-lang | adds OBS apt source, installs Crystal | Run once during bootstrap |
| `pkg.cloudflare.com/cloudflare-main.gpg` | Cloudflare | apt repo signing key | Trust to install cloudflared |
| `pkg.cloudflare.com/cloudflared <suite> main` | Cloudflare | apt repo for cloudflared | Suite resolved at runtime — try `trixie`, fall back to `bookworm` |

## 🆕 New files in this repo

| Path | Purpose | Key contents |
|------|---------|--------------|
| `deploy/lxc/README.md` | Operator guide | Manual prereqs, usage, troubleshooting |
| `deploy/lxc/VERSIONS` | Pinned versions in one place | `INVIDIOUS_TAG=v2.20260207.0`, `COMPANION_TAG=release-master`, `CLOUDFLARED_VERSION=...`, `LXC_HOST=10.10.1.44`, `LXC_USER=root` |
| `deploy/lxc/lib/common.sh` | Shared bash helpers | `ssh_run()`, `ssh_remote()` (heredoc → `bash -s`), `ssh_push_file()` (atomic local→remote write), `read_versions()`, `log_info`/`log_ok`/`log_warn`/`log_err`/`die`, plus a shared `SSH_OPTS` array with ControlMaster multiplexing |
| `deploy/lxc/lib/prereq-check.sh` | Validates manual prereqs | Checks: SSH connects, `~/.cloudflared/cert.pem` exists, `karst.live` zone reachable via cloudflared |
| `deploy/lxc/provision.sh` | One-shot bootstrap (idempotent) | Runs every phase 1–6 in order |
| `deploy/lxc/deploy.sh` | Theme deploy (idempotent, repeatable) | Fetch upstream CSS for pinned tag, concat with theme/vidi.css, atomic write to LXC, reload Invidious |
| `deploy/lxc/config/invidious-config.yml.tpl` | Templated Invidious config | `envsubst`-style placeholders for db password, hmac, companion key, domain |
| `deploy/lxc/config/cloudflared-config.yml.tpl` | Templated cloudflared config | Tunnel UUID + hostname → localhost:3000 mapping |
| `deploy/lxc/config/systemd/invidious.service` | Main Invidious service | Hardening (`NoNewPrivileges`, `PrivateTmp`, `ProtectSystem=strict`, `ProtectHome=read-only` + `ReadWritePaths`). `After=` companion is soft (no `Wants=`) — companion failure won't block UI. |
| `deploy/lxc/config/systemd/invidious.timer` | Hourly restart timer | `OnUnitActiveSec=1h`, fires `invidious-restart.service`. No `Persistent=true` — avoids wasted immediate fire on first enable. |
| `deploy/lxc/config/systemd/invidious-restart.service` | Oneshot wrapper for the timer | `Type=oneshot`, runs `systemctl try-restart invidious.service`. No `Requires=`/`After=` deps — earlier version with those caused a SIGTERM loop. |
| `deploy/lxc/config/systemd/invidious-companion.service` | Companion service | `EnvironmentFile=/etc/invidious/secrets.env` provides `SERVER_SECRET_KEY`. Same hardening minus `PrivateTmp` (Deno binary references /tmp paths). |
| `deploy/lxc/config/systemd/cloudflared.service` | (Already provided by cloudflared apt package; we may override or leave default) | Default works — we configure `/etc/cloudflared/config.yml` only |

## 📂 Live paths on the LXC (created by provision)

| Path | Mode | Owner | Created by |
|------|------|-------|-----------|
| `/home/invidious/invidious/` | 0755 | invidious | `git clone` during provision |
| `/home/invidious/invidious/.built_tag` | 0644 | invidious | Build idempotency marker — contains `INVIDIOUS_TAG` last compiled |
| `/home/invidious/invidious/config/config.yml` | symlink | invidious | Symlink → `/etc/invidious/config.yml` (Invidious only reads cwd-relative path) |
| `/home/invidious/invidious-companion/` | 0755 | invidious | Extract tarball |
| `/home/invidious/invidious-companion/.installed_tag` | 0644 | invidious | Companion idempotency marker — contains `COMPANION_TAG` last installed |
| `/home/invidious/tmp/` | 0700 | invidious | Companion bind path (downloads/cache) |
| `/var/tmp/youtubei.js/` | 0700 | invidious | Companion bind path (browser-engine state) |
| `/etc/invidious/config.yml` | 0640 | invidious:invidious | Rendered via `envsubst` under `umask 027` |
| `/etc/invidious/secrets.env` | 0600 | invidious:invidious | Generated once, persisted forever |
| `/etc/cloudflared/vidi.json` | 0600 | root:root | `cloudflared tunnel create vidi` writes here (Batch 3) |
| `/etc/cloudflared/config.yml` | 0644 | root:root | Rendered from template (Batch 3) |
| `/etc/systemd/system/invidious.service` | 0644 | root:root | Pushed via `ssh_push_file` |
| `/etc/systemd/system/invidious-restart.service` | 0644 | root:root | Pushed via `ssh_push_file` (oneshot wrapper for timer) |
| `/etc/systemd/system/invidious.timer` | 0644 | root:root | Pushed via `ssh_push_file` |
| `/etc/systemd/system/invidious-companion.service` | 0644 | root:root | Pushed via `ssh_push_file` |
