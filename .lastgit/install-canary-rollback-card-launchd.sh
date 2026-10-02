#!/usr/bin/env bash
# Install a host-local launchd agent that files kanban cards from open
# schema-canary-rollback GitHub issues. The GitHub-hosted ticker cannot
# open the LastDB socket; this agent is the board writer.
set -euo pipefail

REPO_SLUG="schema-infra"
LABEL="com.edgevector.schema-canary-rollback-card"
LOG_DIR="${LASTGIT_DEPLOY_LOG_DIR:-$HOME/.lastgit/deploy-${REPO_SLUG}}"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
DEFAULT_PLIST="${LAUNCH_AGENTS_DIR}/${LABEL}.plist"
PLIST="${LASTGIT_DEPLOY_PLIST:-$DEFAULT_PLIST}"
DOMAIN="gui/$(id -u)"
CMD="${1:-install}"
INSTALLER_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_REL="scripts/deploy/canary-rollback-card.sh"

mkdir -p "$LOG_DIR"
mkdir -p "$LAUNCH_AGENTS_DIR" 2>/dev/null || true
if [ -z "${LASTGIT_DEPLOY_PLIST:-}" ] && { [ ! -d "$LAUNCH_AGENTS_DIR" ] || [ ! -w "$LAUNCH_AGENTS_DIR" ]; }; then
  PLIST="${LOG_DIR}/${LABEL}.plist"
fi
mkdir -p "$(dirname "$PLIST")"

resolve_repo_root() {
  local c
  for c in \
    "${LASTGIT_CANARY_REPO_ROOT:-}" \
    "$HOME/.lastgit/deploy-checkouts/${REPO_SLUG}" \
    "$INSTALLER_ROOT" \
    "$HOME/code/edgevector/${REPO_SLUG}"
  do
    [ -n "${c:-}" ] || continue
    if [ -x "$c/$SCRIPT_REL" ]; then
      printf '%s\n' "$c"
      return 0
    fi
  done
  return 1
}

REPO_ROOT="$(resolve_repo_root)" || {
  echo "FAIL: no ${REPO_SLUG} root with $SCRIPT_REL" >&2
  exit 1
}

case "$CMD" in
  install)
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${REPO_ROOT}/${SCRIPT_REL}</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>${HOME}</string>
    <key>PATH</key><string>${HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    <key>LASTGIT_DEPLOY_LOG_DIR</key><string>${LOG_DIR}</string>
    <key>LASTGIT_SOCKET</key><string>${HOME}/.lastdb/data/folddb.sock</string>
    <key>CANARY_ROLLBACK_REPO</key><string>EdgeVector/${REPO_SLUG}</string>
  </dict>
  <key>StartInterval</key><integer>900</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>${LOG_DIR}/canary-rollback-card.launchd.log</string>
  <key>StandardErrorPath</key><string>${LOG_DIR}/canary-rollback-card.launchd.log</string>
</dict>
</plist>
EOF
    if [ "${LASTGIT_CANARY_SKIP_LAUNCHCTL:-}" != "1" ]; then
      launchctl bootout "${DOMAIN}/${LABEL}" 2>/dev/null || true
      launchctl enable "${DOMAIN}/${LABEL}" 2>/dev/null || true
      launchctl bootstrap "$DOMAIN" "$PLIST"
    fi
    echo "installed $LABEL -> $PLIST"
    echo "  script=${REPO_ROOT}/${SCRIPT_REL}"
    ;;
  uninstall)
    if [ "${LASTGIT_CANARY_SKIP_LAUNCHCTL:-}" != "1" ]; then
      launchctl bootout "${DOMAIN}/${LABEL}" 2>/dev/null || true
    fi
    rm -f "$PLIST"
    echo "unloaded ${LABEL}"
    ;;
  status)
    echo "expected script: ${REPO_ROOT}/${SCRIPT_REL}"
    echo "expected plist: ${PLIST}"
    if [ -f "$PLIST" ]; then
      plutil -p "$PLIST" 2>/dev/null | sed -n '1,80p' || true
    fi
    ;;
  *)
    echo "usage: $0 install|uninstall|status" >&2
    exit 2
    ;;
esac
