# 📋 Sprint Roadmap — LXC Provisioning + Theme Deploy

**Plan:** [planning/lxc-provisioning/plan.md](../planning/lxc-provisioning/plan.md)
**Total tasks:** 14 | **Total difficulty:** 44 | **Estimated batches:** 3

---

## Batch 1: Foundation + System bootstrap + Postgres (Difficulty: 15)

_What you'll see after this:_ A bare Debian 13 LXC turns into a baseline host: SSH'able, build deps installed, RAM floor verified, `invidious` user exists, PostgreSQL 17 running with `invidious` role + db ready. No Invidious yet. The repo gets a `deploy/lxc/` skeleton with a working `prereq-check.sh` that fails fast if anything's missing.

| # | Task | Diff | Plain English |
|---|------|------|---------------|
| 1.1 | Create repo skeleton | 2 | Empty placeholder files for everything we'll fill in — `provision.sh`, `deploy.sh`, `lib/`, `config/`, `VERSIONS`, `README.md`. Sets up the structure. |
| 1.2 | Write `lib/common.sh` | 4 | Shared bash helpers used by every script: `ssh_run`, `ssh_remote`, `ssh_push_file`, `log_*`, `read_versions`, with SSH ControlMaster multiplexing baked into `SSH_OPTS`. Write once, reuse everywhere. |
| 1.3 | Write `lib/prereq-check.sh` | 3 | Sanity check that runs first: confirms SSH works, your Cloudflare cert.pem exists, `cloudflared` CLI is installed on the Mac. Fails fast with a clear message instead of getting halfway. |
| 1.4 | Write `deploy/lxc/README.md` | 2 | The operator manual — manual prereqs (SSH key setup, `cloudflared tunnel login`) with copy-pasteable commands. |
| 2.1 | apt baseline + locale + timezone + RAM-floor check | 3 | First section of provision.sh: bring the LXC up to date, set locale and timezone, assert RAM ≥ 2500 MB (Crystal compile peaks ~2.5GB; in-LXC `swapon` is kernel-blocked, so swap is host-managed via `pct set <CTID> -swap`). |
| 2.2 | Install build deps + create `invidious` user | 2 | One apt install of all the C libs Invidious needs to build, plus `pwgen`, `git`, `make`, `gettext-base`, `jq`. Create the system user. |
| 3.1 | Install Postgres + bootstrap secrets + DB role | 4 | Install Postgres 17, generate `secrets.env` (DB password, HMAC key, companion key) once and persist on the LXC at 0600, create the `invidious` Postgres role + database. |

**Checkpoint — what to test before approving Batch 1:**
- `ssh root@10.10.1.44 'systemctl is-active postgresql'` → `active`
- `ssh root@10.10.1.44 'runuser -u postgres -- psql -c "\du invidious"'` → role listed
- `ssh root@10.10.1.44 'cat /etc/invidious/secrets.env'` → 3 lines, all populated, file is 0600 owner invidious
- `ssh root@10.10.1.44 'free -m'` → total RAM ≥ 3000 MB (RAM-floor guard requires ≥2500)
- Re-run `./provision.sh` → exits clean, no destructive changes

---

## Batch 2: Invidious + Companion running locally (Difficulty: 13)

_What you'll see after this:_ Inside the LXC, Invidious is reachable at `http://127.0.0.1:3000` and invidious-companion at `http://127.0.0.1:8282`. You can `curl` either from inside the LXC (no public DNS yet — Batch 3). systemd timer set up to restart Invidious every hour. The Crystal build is the slow step — upstream estimates 10–20 minutes; on this LXC it ran in ~2 min.

| # | Task | Diff | Plain English |
|---|------|------|---------------|
| 4.1 | Install Crystal + clone Invidious at pinned tag | 3 | Run the official Crystal installer (as root, no sudo — bare Debian doesn't ship sudo), clone Invidious to `/home/invidious/invidious` as the `invidious` user, check out `v2.20260207.0`. |
| 4.2 | Build Invidious + run DB migrations | 3 | `runuser -u invidious -- make`, then `./invidious --migrate` to create the schema. (Order note: config.yml render (4.3a) actually has to run **before** migrate because Invidious needs the DB connection settings to migrate.) |
| 4.3 | Render config.yml + install systemd unit + hourly timer | 4 | Fill in the config template with secrets, symlink to `./config/config.yml` in the source tree (Invidious only reads the cwd-relative path), install three systemd units (`invidious.service`, `invidious-restart.service` oneshot wrapper, `invidious.timer`), enable and start everything. |
| 5.1 | Download + extract companion binary | 2 | Pull `invidious_companion-x86_64-unknown-linux-gnu.tar.gz` from GitHub releases, extract to `/home/invidious/invidious-companion/`. |
| 5.2 | Install companion systemd unit + matching secret | 3 | Copy unit file, replace hardcoded secret with `EnvironmentFile=/etc/invidious/secrets.env`, enable and start. The same `SERVER_SECRET_KEY` value is also in Invidious's config.yml as `invidious_companion_key` — they have to match for video playback to work. |

**Checkpoint — what to test before approving Batch 2:**
- `ssh root@10.10.1.44 'systemctl status invidious invidious-companion'` → both `active (running)`
- `ssh root@10.10.1.44 'curl -sf http://127.0.0.1:3000/api/v1/stats | jq .software'` → Invidious version JSON
- `ssh root@10.10.1.44 'curl -sIf http://127.0.0.1:8282'` → any HTTP response (proves it's listening)
- `ssh root@10.10.1.44 'systemctl list-timers invidious.timer'` → next run within 1h
- `ssh root@10.10.1.44 'journalctl -u invidious -n 20 --no-pager'` → clean startup, no errors
- Re-run `./provision.sh` → still idempotent (no rebuild because tag is pinned)

---

## Batch 3: Public access + Theme + Idempotency hardening (Difficulty: 16)

_What you'll see after this:_ `https://vidi.karst.live` loads in your browser, valid TLS, works end-to-end (sign up, watch a video). Editing `theme/vidi.css` and running `./deploy.sh` shows changes within seconds. Re-running everything is a clean no-op.

| # | Task | Diff | Plain English |
|---|------|------|---------------|
| 6.1 | Create tunnel + DNS route from Mac | 4 | Using your Mac's `cloudflared` CLI: check if a tunnel named `vidi` already exists; create it if not. Route `vidi.karst.live` to it. Capture the tunnel UUID and credentials JSON. |
| 6.2 | Install cloudflared on LXC + push credentials + config | 3 | Add Cloudflare apt repo, install cloudflared. `scp` the credentials JSON to `/etc/cloudflared/`. Render the config template (tunnel UUID + hostname → `localhost:3000`). Enable and start the systemd service. |
| 7.1 | Write `deploy.sh` (theme override pipeline) | 5 | Standalone script: fetch upstream `default.css` for the pinned tag, concat with `theme/vidi.css`, hash to detect no-op, atomic write to LXC, restart Invidious. `provision.sh` calls it as its last step so first-time setup ends with the theme applied. |
| 8.1 | Re-run provision and verify no-op | 2 | Run `./provision.sh` on the already-provisioned LXC. Should exit clean with no service restarts beyond `deploy.sh`'s expected one. Fix any non-idempotent step uncovered. |
| 8.2 | Cosmetic theme tweak deploy | 2 | Add a single `body { background: red }` to `theme/vidi.css`, run `./deploy.sh`, refresh browser. Then run again with no changes — exits without restarting Invidious. |

**Checkpoint — what to test before approving Batch 3:**
- `curl -sIf https://vidi.karst.live` → `200 OK`, valid TLS
- Browser to `https://vidi.karst.live` → Invidious loads
- Sign up a test user, log in, log out, sign up second user — all work
- Watch any video for 30s — proves companion working end-to-end
- `curl -s https://vidi.karst.live/css/default.css | tail -20` → contains your `theme/vidi.css` rules
- Edit `theme/vidi.css`, run `./deploy.sh`, hard-refresh browser → change visible
- Run `./deploy.sh` again with no edits → exits in <2s, no Invidious restart

---

## ⚠️ Watch Out For

| Concern | When | What to do |
|---------|------|-----------|
| `cloudflared tunnel login` not done yet | Before any run | `prereq-check.sh` will tell you. One-time browser flow on Mac. |
| Crystal install fails on Trixie via OBS | Batch 2 task 4.1 | Fallback is to use Bookworm packages (binary-compatible). Plan documents the fallback. |
| Crystal compile OOMs | Batch 2 task 4.2 | Should be impossible with the LXC's 3GB RAM + 512MB host swap (Crystal peaks ~2.5GB). RAM-floor check in Phase 2.1 aborts if RAM < 2500 MB. If a future version peaks higher: `pct set <CTID> -memory 4096 -swap 2048` from the Proxmox host. |
| systemd hardening fails in LXC | Batch 2 task 5.2 | Companion's upstream unit uses `ProtectKernelModules` etc. If `journalctl` shows mount-namespace errors, drop the failing directives. Don't silently ignore. |
| Hourly timer interrupts you mid-video | Ongoing | Acceptable for a personal instance. Restart takes ~2s. Document the trade-off in README. |
| Tunnel UUID rotates on rerun | Batch 3 task 6.1 | Idempotent guard: `cloudflared tunnel list` first. Only create if missing. |
| Theme deploy mid-restart | Batch 3 task 7.1 | Worst case: deploy waits for restart to finish. Acceptable. |
| `make` rebuild on re-provision clobbers theme | Batches 2+3 | `provision.sh` ends by calling `deploy.sh` to restore overrides. Documented as a contract. |
