#!/usr/bin/env bash
# Install a host-local launchd agent that files kanban cards from open
# GitHub issues labeled schema-canary-rollback.
#
# The GitHub-hosted ticker cannot open folddb.sock. This agent is the board
# writer. It must run on a host that can reach ~/.lastdb/data/folddb.sock.
set -euo pipefail

REPO_SLUG="schema-infra"
LABEL="com.edgevector.schema-canary-rollback-card"
LOG_DIR="${LASTGIT_DEPLOY_LOG_DIR:-$HOME/.lastgit/deploy-${REPO_SLUG}}"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
DEFAULT_PLIST="${LAUNCH_AGENTS_DIR}/${LABEL}.plist"
PLIST="${SCHEMA_CANARY_CARD_PLIST:-$DEFAULT_PLIST}"
DOMAIN="gui/$(id -u)"
CMD="${1:-install}"
INSTALLER_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="${INSTALLER_ROOT}/scripts/deploy/file-canary-rollback-cards.sh"
DST="${LOG_DIR}/file-canary-rollback-cards.sh"
WRAPPER="${LOG_DIR}/canary-rollback-card-wrapper.sh"

mkdir -p "$LOG_DIR"
mkdir -p "$LAUNCH_AGENTS_DIR" 2>/dev/null || true
if [ -z "${SCHEMA_CANARY_CARD_PLIST:-}" ] && { [ ! -d "$LAUNCH_AGENTS_DIR" ] || [ ! -w "$LAUNCH_AGENTS_DIR" ]; }; then
  PLIST="${LOG_DIR}/${LABEL}.plist"
fi
mkdir -p "$(dirname "$PLIST")"

write_wrapper() {
  if [ ! -f "$SRC" ]; then
    echo "FAIL: missing $SRC" >&2
    return 1
  fi
  cp -f "$SRC" "$DST"
  chmod +x "$DST"
  cat >"$WRAPPER" <<WRAP
#!/usr/bin/env bash
set -euo pipefail
export HOME="\${HOME:-$HOME}"
export PATH="\$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
export SCHEMA_CANARY_ISSUE_REPO="\${SCHEMA_CANARY_ISSUE_REPO:-EdgeVector/schema-infra}"
export SCHEMA_CANARY_CARD_REPO="\${SCHEMA_CANARY_CARD_REPO:-EdgeVector/schema-infra}"
exec /bin/bash "$DST"
WRAP
  chmod +x "$WRAPPER"
}

write_plist() {
  cat >"$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${WRAPPER}</string>
  </array>
  <key>StartInterval</key>
  <integer>900</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${LOG_DIR}/canary-rollback-card.out.log</string>
  <key>StandardErrorPath</key>
  <string>${LOG_DIR}/canary-rollback-card.err.log</string>
</dict>
</plist>
PLIST
}

case "$CMD" in
  install)
    write_wrapper
    write_plist
    if command -v launchctl >/dev/null 2>&1; then
      launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
      launchctl bootstrap "$DOMAIN" "$PLIST" >/dev/null
    fi
    echo "installed $LABEL plist=$PLIST wrapper=$WRAPPER"
    ;;
  status)
    echo "plist=$PLIST"
    echo "wrapper=$WRAPPER"
    echo "script=$DST"
    if command -v launchctl >/dev/null 2>&1; then
      launchctl print "$DOMAIN/$LABEL" 2>/dev/null | head -n 20 || echo "agent not loaded"
    fi
    ;;
  uninstall)
    if command -v launchctl >/dev/null 2>&1; then
      launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
    fi
    echo "unloaded $LABEL"
    ;;
  *)
    echo "usage: $0 install|status|uninstall" >&2
    exit 2
    ;;
esac
