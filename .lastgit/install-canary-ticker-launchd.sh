#!/usr/bin/env bash
# Install launchd agent that runs canary-ticker every 15 minutes.
#
# Resolves a *durable* repo root (mirror clone preferred) so the agent does not
# break when a one-shot ship-checkout is deleted after deploy.
set -euo pipefail

REPO_SLUG="schema-infra"
LABEL="com.edgevector.lastgit-canary-ticker-${REPO_SLUG}"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
LOG_DIR="${LASTGIT_DEPLOY_LOG_DIR:-$HOME/.lastgit/deploy-${REPO_SLUG}}"
mkdir -p "$LOG_DIR" "$HOME/Library/LaunchAgents"

resolve_repo_root() {
  local c
  for c in \
    "${LASTGIT_CANARY_REPO_ROOT:-}" \
    "$HOME/.lastgit/mirror-clones/${REPO_SLUG}" \
    "$(cd "$(dirname "$0")/.." && pwd)" \
    "$HOME/code/edgevector/${REPO_SLUG}"
  do
    [ -n "${c:-}" ] || continue
    if [ -x "$c/.lastgit/canary-ticker.sh" ] && [ -f "$c/scripts/deploy/canary-lib.sh" ]; then
      printf '%s\n' "$c"
      return 0
    fi
  done
  return 1
}

REPO_ROOT="$(resolve_repo_root)" || {
  echo "FAIL: no durable ${REPO_SLUG} root with .lastgit/canary-ticker.sh + scripts/deploy/canary-lib.sh" >&2
  echo "  tried LASTGIT_CANARY_REPO_ROOT, ~/.lastgit/mirror-clones/${REPO_SLUG}, installer parent, ~/code/edgevector/${REPO_SLUG}" >&2
  exit 1
}
TICKER="${REPO_ROOT}/.lastgit/canary-ticker.sh"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${TICKER}</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>${HOME}</string>
    <key>PATH</key><string>/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin</string>
    <key>LASTGIT_DEPLOY_LOG_DIR</key><string>${LOG_DIR}</string>
    <key>AWS_PROFILE</key><string>default</string>
  </dict>
  <key>StartInterval</key><integer>900</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>${LOG_DIR}/canary-ticker.launchd.log</string>
  <key>StandardErrorPath</key><string>${LOG_DIR}/canary-ticker.launchd.log</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "installed $LABEL → $PLIST"
echo "  ticker=$TICKER"
echo "  repo_root=$REPO_ROOT"
echo "  log_dir=$LOG_DIR"
