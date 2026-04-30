# vidi

> Self-hosted [Invidious](https://github.com/iv-org/invidious) with a modern glass theme.

A pure-CSS reskin of Invidious — translucent surfaces, soft shadows, rounded corners, modern typography. Deployed on a Proxmox LXC with no fork and no Crystal recompile.

## How it works

The theme lives in `theme/vidi.css`. On deploy, an idempotent script concatenates upstream Invidious's `default.css` with `vidi.css` and writes the result to the live `assets/css/default.css`. No template patches, no fork — when Invidious releases, re-fetch their stylesheet, re-concatenate, redeploy.

## Status

✅ LXC provisioning + theme deploy pipeline shipped ([PR #1](https://github.com/nicolasiorio/vidi/pull/1)). Live at `vidi.karst.live`: two idempotent scripts (`deploy/lxc/provision.sh`, `deploy/lxc/deploy.sh`) take a bare Debian 13 LXC to a fully working Invidious + invidious-companion + Postgres + cloudflared stack with the theme applied. See [`deploy/lxc/README.md`](deploy/lxc/README.md) for the operator manual.

🚧 Theme content next — `theme/vidi.css` currently ships empty; the actual glass-aesthetic rules land in a follow-up spec.

## License

MIT — see [LICENSE](LICENSE). Note that the upstream Invidious project is AGPLv3; this repo never links or embeds Invidious source. The interface is the static asset boundary.
