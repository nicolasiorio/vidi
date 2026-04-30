#!/usr/bin/env bash
# vidi/deploy/lxc/deploy.sh
# Theme push pipeline — fetch upstream CSS for pinned tag, concatenate with
# theme/vidi.css, atomic write to LXC, restart Invidious.
# Implementation lands in build Batch 3 (Task 7.1).
set -euo pipefail

die() { printf '[✗] %s\n' "$*" >&2; exit 1; }
die "deploy.sh not yet implemented — see Task 7.1 in planning/lxc-provisioning/plan.md"
