# 🧠 Architecture Notes — LXC Provisioning + Theme Deploy

## End-state diagram

```
┌─ Mac (control plane) ──────────────────────────────────────┐
│  ~/Developer/vidi/                                         │
│  ├── deploy/lxc/provision.sh    (one-shot bootstrap)       │
│  ├── deploy/lxc/deploy.sh       (idempotent theme push)    │
│  └── ~/.cloudflared/cert.pem    (manual prereq, 0600)      │
│                  │                                          │
│                  │ ssh root@10.10.1.44                      │
│                  ▼                                          │
└────────────────────────────────────────────────────────────┘
                   │
┌─ LXC 10.10.1.44 (Debian 13) ───────────────────────────────┐
│                                                             │
│  PostgreSQL 17 (localhost:5432)                             │
│    └── db `invidious` owned by role `invidious`            │
│                                                             │
│  Invidious v2.20260207.0 (localhost:3000)                  │
│    ├── /home/invidious/invidious/        (source + binary) │
│    ├── /etc/invidious/config.yml         (mode 0640)       │
│    ├── /etc/invidious/secrets.env        (mode 0600)       │
│    ├── systemd: invidious.service                          │
│    ├── systemd: invidious.timer    (OnUnitActiveSec=1h)    │
│    └── systemd: invidious-restart.service                  │
│                 └─ oneshot: `systemctl try-restart invidious` │
│              │                                              │
│              │ HTTP /companion → 8282                       │
│              ▼                                              │
│  invidious-companion (localhost:8282)                       │
│    ├── /home/invidious/invidious-companion/  (Deno binary) │
│    └── systemd: invidious-companion.service                │
│              │                                              │
│              │ outbound HTTPS → youtube.com                 │
│              ▼                                              │
│         (the internet)                                      │
│                                                             │
│  cloudflared (tunnel: vidi)                                 │
│    ├── /etc/cloudflared/vidi.json  (creds, 0600 root)      │
│    ├── /etc/cloudflared/config.yml (route hostname → 3000) │
│    └── systemd: cloudflared.service                        │
└────────────────────────────────────────────────────────────┘
                   │
                   │ outbound persistent tunnel (no inbound ports)
                   ▼
              Cloudflare edge ◄─── DNS: vidi.karst.live (CNAME → tunnel UUID)
                   │
                   │ TLS terminated at edge
                   ▼
              End user (browser)
```

## 🔑 Why this shape

**No public ports.** Both Invidious and Postgres bind `127.0.0.1`. Only ingress is the cloudflared tunnel, which establishes outbound from inside the LXC. No firewall rules, no NAT, no port forwarding.

**Companion is mandatory.** Since `inv-sig-helper` was deprecated, video stream resolution is delegated to `invidious-companion`. Without it, every video page loads but playback fails. It's a separate process so YouTube's bot countermeasures (which target the resolver, not the front-end) can be patched independently of Invidious itself.

**Hourly restart.** Upstream warns that Invidious must be restarted "ideally every hour" — likely because long-lived state caches (cookies, session tokens) drift. We use a systemd `OnUnitActiveSec=1h` timer rather than a cron job because the timer survives reboots and respects unit dependencies cleanly.

**Two secrets.**
- `hmac_key`: signs Invidious's own session tokens. 32+ random hex chars. Stored in `/etc/invidious/secrets.env`; baked into `/etc/invidious/config.yml` at render time (Invidious does not read env vars — `config.yml` is its only source).
- `invidious_companion_key`: shared secret between Invidious and companion. Must be **exactly 16 chars** per upstream. Same value lives in two places: as `invidious_companion_key:` in Invidious's `config.yml`, and as `SERVER_SECRET_KEY=` line in `secrets.env` (the companion systemd unit pulls it via `EnvironmentFile=/etc/invidious/secrets.env`).

**Theme override is post-build.** Invidious's `make` builds the Crystal binary but does not bundle CSS — assets are served from disk (`/home/invidious/invidious/assets/css/default.css`). So our deploy mechanism is: fetch upstream `default.css` for the pinned tag, concatenate with `theme/vidi.css`, write atomically to the live path, then **restart Invidious** (the Crystal binary doesn't honour `SIGHUP` for asset reload — confirmed during /build). **Caveat:** `make` would clobber the override on rebuild → provision.sh ends by invoking deploy.sh.

## 🔌 Idempotency strategy

Every step uses one of these patterns:

| Pattern | Used for |
|---------|----------|
| `apt-get install -y <pkg>` (apt is naturally idempotent) | All apt installs |
| `id <user> >/dev/null 2>&1 \|\| useradd ...` | User creation |
| `[ -f /etc/invidious/secrets.env ] \|\| generate_secrets` | One-shot secret generation |
| `runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='invidious'" \| grep -q 1 \|\| psql -c "CREATE ROLE ..."` | Postgres role/db (bare Debian has no `sudo`; we use `runuser` from util-linux) |
| `cd /home/invidious/invidious && git fetch --tags && git checkout $TAG` | Source pin (no-op if already on tag) |
| `cmp -s old new \|\| install -m ... new old && systemctl reload-or-restart` | Config file changes |
| `cloudflared tunnel list \| grep -q vidi \|\| cloudflared tunnel create vidi` | Tunnel creation |

## ⚠️ Known sharp edges

1. **Crystal install on Trixie.** The official `crystal-lang.org/install.sh` script uses OBS. Trixie support depends on OBS. If it fails, fall back to manual sources.list with `bookworm` packages (Crystal binaries are libc-version-tolerant).
2. **RAM floor for Crystal compile.** Upstream says 2.5GB minimum. ~~Provision must add a 2GB swap file *before* `make`.~~ Updated during /build: in-LXC `swapon` is kernel-blocked, so swap can't be created from inside the container. Provision asserts RAM ≥ 2500 MB; if a future bump is needed, set it from the Proxmox host (`pct set <CTID> -memory 4096 -swap 2048`). Current LXC has 3GB + 512MB host swap, sufficient.
3. **systemd hardening in LXC.** Some `Protect*=` directives need namespace support. Most modern LXCs (unprivileged, post-Debian 11) work; if any fail with `Failed to set up mount namespacing`, soften incrementally.
4. **`make` rebuild clobbers theme.** Provision must end by calling deploy. Document this contract.
5. **Cloudflare `cert.pem` is a manual prereq.** Without `~/.cloudflared/cert.pem` on the Mac, `cloudflared tunnel create` fails. `prereq-check.sh` exits early with a clear message.
6. **Cloudflared trixie suite may not exist.** Try `trixie`, fall back to `bookworm`. Both Debian releases ship glibc compatible with the same cloudflared binary.
7. **Tunnel is created per-run.** Re-running provision must detect existing tunnel and reuse — `cloudflared tunnel list --output json | jq '.[] | select(.name=="vidi")'`.

## 🧪 Where the design is testable

| Layer | Probe |
|-------|-------|
| Postgres | `runuser -u postgres -- psql -c '\du invidious'` |
| Invidious | `curl -sf http://127.0.0.1:3000/api/v1/stats \| jq .software` |
| Companion | `curl -sf http://127.0.0.1:8282/healthz` (or whatever its health endpoint is — verify in build) |
| Tunnel | `cloudflared tunnel info vidi` (on Mac or LXC), `dig vidi.karst.live` |
| End-to-end | `curl -sfI https://vidi.karst.live` returns 200 with valid TLS |
| Theme applied | `curl -s https://vidi.karst.live/css/default.css \| tail -50` shows vidi.css content |
| Idempotency | Re-run `provision.sh` → exit 0, no service restarts beyond expected |
