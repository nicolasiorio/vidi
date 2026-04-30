#!/usr/bin/env bash
# vidi/deploy/lxc/deploy.sh
# Theme push pipeline. Idempotent — re-runs without changes are a no-op.
#
#   1. Fetch upstream default.css for the pinned Invidious tag from GitHub.
#   2. Concatenate with theme/vidi.css (theme rules win — appended last).
#   3. Compare sha256 against the live remote default.css.
#   4. If different: backup pristine upstream (first run only), atomic push,
#      restart Invidious. Otherwise exit 0.
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &>/dev/null && pwd )"
source "${SCRIPT_DIR}/lib/common.sh"
read_versions

REPO_ROOT="$( cd "${SCRIPT_DIR}/../.." && pwd )"
THEME_CSS="${REPO_ROOT}/theme/vidi.css"
[ -f "$THEME_CSS" ] || die "theme/vidi.css missing at $THEME_CSS"

"${SCRIPT_DIR}/lib/prereq-check.sh"

REMOTE_CSS=/home/invidious/invidious/assets/css/default.css

log_info "Fetching upstream default.css for ${INVIDIOUS_TAG}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

UPSTREAM="${TMP}/upstream.css"
COMBINED="${TMP}/combined.css"

curl -fsSL \
  "https://raw.githubusercontent.com/iv-org/invidious/${INVIDIOUS_TAG}/assets/css/default.css" \
  -o "$UPSTREAM" \
  || die "Failed to fetch upstream default.css for ${INVIDIOUS_TAG}"
[ -s "$UPSTREAM" ] || die "Fetched upstream default.css is empty"

cat "$UPSTREAM" "$THEME_CSS" > "$COMBINED"
NEW_HASH=$(shasum -a 256 "$COMBINED" | cut -d' ' -f1)

# Hash the live remote file (not a marker file): catches the case where
# `make` has restored upstream's default.css since the last theme deploy.
REMOTE_HASH=$(ssh_run "sha256sum '${REMOTE_CSS}' 2>/dev/null | cut -d' ' -f1 || echo none")

if [ "$REMOTE_HASH" = "$NEW_HASH" ]; then
  log_ok "Theme already current (sha256 ${NEW_HASH:0:12}). No-op."
  exit 0
fi

log_info "Theme drift detected (remote ${REMOTE_HASH:0:12} → new ${NEW_HASH:0:12})"

# Snapshot pristine upstream once. Lets an operator restore by hand if the
# theme ever produces something unviewable.
ssh_remote <<'REMOTE'
set -euo pipefail
DIR=/home/invidious/invidious/assets/css
if [ ! -f "$DIR/default.css.upstream.bak" ]; then
  cp -p "$DIR/default.css" "$DIR/default.css.upstream.bak"
fi
REMOTE

log_info "Pushing themed CSS to ${LXC_HOST}"
ssh_push_file "$COMBINED" "$REMOTE_CSS"

ssh_remote <<REMOTE
set -euo pipefail
chown invidious:invidious '${REMOTE_CSS}'
chmod 0644 '${REMOTE_CSS}'
systemctl restart invidious
REMOTE

log_ok "Theme deployed (sha256 ${NEW_HASH:0:12}). Invidious restarted."
