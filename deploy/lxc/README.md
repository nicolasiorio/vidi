# vidi — LXC Deploy

Two scripts that bring a bare Debian 13 LXC up to a fully working themed Invidious instance, then keep the theme redeployable on every change. Both run from the operator's Mac, both are idempotent.

## 🛠 Manual Prerequisites (one-time, before first run)

These cannot be automated — set them up on the Mac before invoking `provision.sh`. The `prereq-check.sh` helper verifies each one and fails fast with a fix command if anything is missing.

### 1. SSH key auth to the LXC

The LXC at `10.10.1.44` is bare Debian 13. From your Mac:

```sh
ssh-copy-id root@10.10.1.44
```

Verify with `ssh root@10.10.1.44 'true'` — should exit `0` silently.

### 2. Cloudflare tunnel auth

Required so the Mac can create + route tunnels in your Cloudflare account.

```sh
brew install cloudflared
cloudflared tunnel login
```

The login flow opens a browser; pick the `karst.live` zone. On success, `~/.cloudflared/cert.pem` is written.

### 3. Cloudflare zone

`karst.live` must already exist in your Cloudflare account. If not, add it via the Cloudflare dashboard before provisioning.

## 🚀 Usage

Both scripts are idempotent — re-running them is always safe.

### First-time bootstrap

```sh
./deploy/lxc/provision.sh
```

Walks every phase: apt baseline → Postgres → Crystal toolchain → Invidious build → companion → cloudflared tunnel → theme deploy. ~20 min wall-clock on first run (Crystal compile dominates). Re-runs exit in seconds.

`provision.sh` ends by calling `deploy.sh` so the theme override survives any `make` rebuild that runs during provisioning.

### Theme push

```sh
./deploy/lxc/deploy.sh
```

Fetches the upstream `default.css` for the pinned Invidious tag, concatenates with `theme/vidi.css` (theme rules win), writes atomically to the LXC, restarts Invidious. Skips the restart when the output is byte-identical to the previous deploy.

## 📌 Pinned versions

See `VERSIONS`. To bump Invidious:

1. Edit `INVIDIOUS_TAG` in `VERSIONS`.
2. Run `./deploy/lxc/provision.sh` — re-clones, rebuilds, re-runs migrations, re-fetches matching upstream CSS.
3. Smoke-test `https://vidi.karst.live` in a browser.

## 🛟 Troubleshooting

| Symptom | First check |
|---------|-------------|
| `provision.sh` fails at prereq-check | Read the error — it names the missing prereq + the fix command. |
| Crystal build OOM-killed | LXC needs >2.5GB RAM. Swap is host-managed (LXC can't `swapon` from inside). Verify `ssh root@10.10.1.44 'free -m'` shows ≥3GB. To bump: `pct set <CTID> -memory 4096 -swap 2048` on the Proxmox host. |
| Invidious won't start | `ssh root@10.10.1.44 'journalctl -u invidious -n 100 --no-pager'`. |
| Companion key length error | `SERVER_SECRET_KEY` must be exactly 16 chars. Inspect `/etc/invidious/secrets.env` (mode 0600, owner invidious). |
| Tunnel returns 502 | `ssh root@10.10.1.44 'systemctl status cloudflared invidious invidious-companion'`; all three must be active. |
| Theme not visible | Hard-reload the browser; `curl -s https://vidi.karst.live/css/default.css \| tail -20` should show vidi rules at the bottom. |

## 📂 File layout

```
deploy/lxc/
├── README.md             ← this file
├── VERSIONS              ← pinned versions (Invidious tag, companion tag, host)
├── provision.sh          ← one-shot bootstrap (idempotent)
├── deploy.sh             ← theme push (idempotent)
├── lib/
│   ├── common.sh         ← shared bash helpers
│   └── prereq-check.sh   ← validates manual prereqs
└── config/
    ├── invidious-config.yml.tpl
    ├── cloudflared-config.yml.tpl
    └── systemd/
        ├── invidious.service
        ├── invidious.timer
        └── invidious-companion.service
```
