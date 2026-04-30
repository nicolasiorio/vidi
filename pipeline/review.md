# 🔍 Review: LXC Provisioning + Theme Deploy

**Date:** 2026-05-01
**Branch:** `feature/lxc-provisioning`
**Commits reviewed:** `b492bc9` → `9d0ab22` (5 commits, 17 tasks across 3 batches)

## 📋 Summary

Solid infrastructure work. Every spec FR is implemented and verified live on the prod LXC. Idempotency holds: full `provision.sh` re-run is a clean no-op, `deploy.sh` no-op skips the Invidious restart. One ≥75-confidence finding identified and fixed: deploy.sh had two undocumented Mac-side prereqs (`gh` + `sha256sum`) — both replaced with macOS-default tooling, dropping the prereqs entirely.

## Code Review

**Verdict:** ✅ Approved (after fix)

### Requirements traceability

| Req | ✅ | Where it lives | Notes |
|-----|:--:|---|---|
| FR-001 LXC bootstrap | ✅ | `provision.sh` Phase 2.1, 2.2 | RAM-floor `<2500MB → die`, locale + tz idempotent guards, full apt dep list |
| FR-002 Postgres | ✅ | `provision.sh` Phase 3.1 | Role + DB idempotent (`pg_roles`/`pg_database` checks), `secrets.env` gated by `[ ! -f ]` |
| FR-003 Invidious install | ✅ | `provision.sh` Phase 4.1, 4.2, 4.3b + systemd units | `.built_tag` skips rebuild; oneshot wrapper in `invidious-restart.service` avoids the SIGTERM-loop bug from earlier draft |
| FR-004 Invidious config | ✅ | `config/invidious-config.yml.tpl` + Phase 4.3a | Mode 0640 owner invidious, hmac_key 64-hex, companion_key 16-hex |
| FR-005 Cloudflared | ✅ | `provision.sh` Phase 6.1 + 6.2 + `cloudflared-config.yml.tpl` | Tunnel reuse + DNS dedup verified live |
| FR-006 Theme deploy | ✅ | `deploy.sh` | Hashes live remote file (deviation from plan's marker-file approach — robust against `make` clobber) |
| FR-007 Idempotency | ✅ | every phase has explicit guards | Full re-run no-op verified live |
| FR-008 Prereqs | ✅ | `README.md` + `prereq-check.sh` | Hidden `gh` + `sha256sum` deps removed in fix commit `9d0ab22` |
| FR-009 Companion | ✅ | `provision.sh` Phase 5.1 + 5.2 + companion unit | Companion key shared via `secrets.env` `EnvironmentFile` |

### Findings ≥75 confidence

**🟠 Major — Hidden Mac-side prereqs in `deploy.sh`** (confidence 80, traces to FR-008)

`deploy.sh` required two Mac-side tools that don't ship on macOS by default and weren't listed in `README.md` or checked by `prereq-check.sh`:

- `gh` CLI **with authenticated context** — used to fetch upstream `default.css`
- `sha256sum` — used to hash the combined CSS

A fresh operator would hit `command not found` errors before any LXC mutation.

**Fix applied (`9d0ab22`):**
- `gh api ... contents/...` → `curl -fsSL https://raw.githubusercontent.com/iv-org/invidious/${TAG}/...` (anonymous, no size limit, identical data)
- `sha256sum` → `shasum -a 256` (Perl-shipped on macOS + Debian by default)

Verified live post-fix: hash matches previous deploys (`014154ed0d16`), no-op idempotency intact.

### Findings dropped (<75)

For the record, considered and dropped:
- `localhost` vs `127.0.0.1` in cloudflared ingress — semantically equivalent (false positive)
- `Wants=invidious-companion.service` missing on `invidious.service` — deliberate per the inline comment (companion failure shouldn't block UI)
- Regex-matching cloudflared output — fragile but acceptable; cloudflared CLI output is stable
- Double prereq-check on full `provision.sh` flow — deliberate to keep `deploy.sh` standalone-runnable
- shellcheck SC2016 on `envsubst '${VAR}'` — false positive, that's the correct allowlist syntax
- `gh api` Contents-API 1MB limit — `default.css` is ~15KB (irrelevant in practice; moot after fix anyway)
- `PrivateTmp=true` missing from companion unit — consistency-only nitpick, no actual exposure (uses `/var/tmp/youtubei.js`, not `/tmp`)

## Fixes Applied

| Finding | Severity | Commit | Status |
|---|---|---|:--:|
| Hidden Mac-side prereqs (`gh`, `sha256sum`) in deploy.sh | 🟠 Major | `9d0ab22` | ✅ Fixed |

## Test Results

Per spec: "This is infrastructure — no unit tests. Validation is end-to-end manual."

End-to-end manual validation done during /build and re-verified post-fix:

| Test | Requirement | Result |
|---|---|:--:|
| `provision.sh` walks every phase clean on fresh LXC | FR-001..005, 009 | ✅ |
| `https://vidi.karst.live` returns 200 with valid TLS | FR-005 | ✅ |
| Public CSS contains theme trailer | FR-006 | ✅ |
| `deploy.sh` round-trip (drift → push → restart, then no-op) | FR-006 | ✅ |
| `provision.sh` re-run = clean no-op | FR-007 | ✅ |
| Operator manual covers all 3 prereqs with copy-paste commands | FR-008 | ✅ |
| Video playback end-to-end | FR-009 | ✅ (operator-confirmed) |

**Requirements coverage:** 9/9 (100%)

## Security Audit

**Verdict:** ✅ Approved

No 🔴 critical or 🟠 high findings.

### 🟡 Medium (defense-in-depth, not blocking)

- **Postgres password passes through argv during `provision.sh` Phase 3.1.** The `psql -c "CREATE ROLE ... PASSWORD '$POSTGRES_PASSWORD'"` exposes the password in `ps -ef` for the duration of that command. On the prod LXC, only `root` (full visibility anyway) and the `invidious` user (locked password, no shell login) exist, so practical exposure is nil. Fixable in a future hardening pass via `psql --set=pass=...` or HEREDOC SQL with `:'pass'` interpolation.
- **`prereq-check.sh` mutates the user's filesystem** (chmods `~/.cloudflared/cert.pem` to 0600 if loose). It's labelled a "check" but tightens perms as a side effect. Strictly safer than leaving it loose — flagged for principle-of-least-surprise rather than as a real risk.

### Verified clean

- ✅ No hardcoded secrets in source (`.env` covered by `.gitignore`; secrets generated on LXC at runtime, never leave it)
- ✅ All secrets `0600` (`secrets.env`, `vidi.json`) or `0640` invidious-owned (`config.yml`, single-member group)
- ✅ Postgres, Invidious, companion all bind `127.0.0.1` only — cloudflared is the sole ingress
- ✅ HTTPS enforced (`https_only: true` in invidious config, Cloudflare TLS terminating)
- ✅ Remote shell commands properly quote interpolated values (no command injection surface)
- ✅ No log/journald leakage of secret values (verified: deploy.sh never echoes secrets; provision.sh redirects `psql` stdout to `/dev/null`)
- ✅ Locked `invidious` system user (`passwd -l`), no shell login surface

## 🏁 Overall Verdict

✅ **Approved** — Ready to ship.

Single review finding fixed in `9d0ab22`. No outstanding work. Defense-in-depth notes are acknowledged but not blocking.

**Next:** `/ship`
