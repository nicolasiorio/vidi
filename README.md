# vidi

> Self-hosted [Invidious](https://github.com/iv-org/invidious) with a modern glass theme.

A pure-CSS reskin of Invidious — translucent surfaces, soft shadows, rounded corners, modern typography. Deployed on a Proxmox LXC with no fork and no Crystal recompile.

## How it works

The theme lives in `theme/vidi.css`. On deploy, an idempotent script concatenates upstream Invidious's `default.css` with `vidi.css` and writes the result to the live `assets/css/default.css`. No template patches, no fork — when Invidious releases, re-fetch their stylesheet, re-concatenate, redeploy.

## Status

🚧 Spec + plan approved (`feature/lxc-provisioning`). Build phase next — provisions the Debian 13 LXC, installs Invidious + invidious-companion + Postgres + cloudflared, and ships the theme deploy pipeline. See [`pipeline/spec.md`](pipeline/spec.md) and [`pipeline/sprint-plan.md`](pipeline/sprint-plan.md).

## License

MIT — see [LICENSE](LICENSE). Note that the upstream Invidious project is AGPLv3; this repo never links or embeds Invidious source. The interface is the static asset boundary.
