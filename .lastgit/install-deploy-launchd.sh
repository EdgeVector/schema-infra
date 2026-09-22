#!/usr/bin/env bash
# Install the durable deploy-pipeline supervisor for schema-infra (forge main).
#
# The plist points at .lastgit/deploy-run.sh inside a forge-tracking checkout:
# ~/.lastgit/deploy-checkouts/schema-infra when it exists, else this installer's
# own repo root; LASTGIT_DEPLOY_REPO_ROOT overrides. deploy-run.sh keeps that
# checkout fast-forwarded to main and re-execs itself when it changes. Until
# 2026-09-21 this copied the runner into LOG_DIR, where nothing refreshed it.
# A root whose origin is not the forge repo is refused.
set -euo pipefail

REPO_SLUG="schema-infra"
LABEL="com.edgevector.lastgit-deploy-${REPO_SLUG}"
LOG_DIR="${LASTGIT_DEPLOY_LOG_DIR:-$HOME/.lastgit/deploy-${REPO_SLUG}}"
INSTALLER_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="${LASTGIT_DEPLOY_REPO_ROOT:-}"
if [ -z "$ROOT" ]; then
  if [ -x "$HOME/.lastgit/deploy-checkouts/${REPO_SLUG}/.lastgit/deploy-run.sh" ]; then
    ROOT="$HOME/.lastgit/deploy-checkouts/${REPO_SLUG}"
  else
    ROOT="$INSTALLER_ROOT"
  fi
fi
RUNNER="${ROOT}/.lastgit/deploy-run.sh"
SOURCE="$RUNNER"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
DEFAULT_PLIST="${LAUNCH_AGENTS_DIR}/${LABEL}.plist"
PLIST="${LASTGIT_DEPLOY_PLIST:-$DEFAULT_PLIST}"
DOMAIN="gui/$(id -u)"
CMD="${1:-install}"

[ -x "$SOURCE" ] || {
  echo "FAIL: deploy runner is not executable: $SOURCE" >&2
  exit 1
}

mkdir -p "$LOG_DIR"
mkdir -p "$LAUNCH_AGENTS_DIR" 2>/dev/null || true

if [ -z "${LASTGIT_DEPLOY_PLIST:-}" ] && { [ ! -d "$LAUNCH_AGENTS_DIR" ] || [ ! -w "$LAUNCH_AGENTS_DIR" ]; }; then
  PLIST="${LOG_DIR}/${LABEL}.plist"
fi
mkdir -p "$(dirname "$PLIST")"

case "$CMD" in
  install)
    # An explicit LASTGIT_DEPLOY_REPO_ROOT is the operator's choice; only an
    # auto-resolved root must track the forge.
    if [ -z "${LASTGIT_DEPLOY_REPO_ROOT:-}" ]; then
      origin="$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)"
      case "$origin" in
        *localhost:3300/EdgeVector/${REPO_SLUG}*|*127.0.0.1:3300/EdgeVector/${REPO_SLUG}*) ;;
        *) echo "refusing: $ROOT origin is '$origin', not the forge repo (see header)" >&2; exit 2 ;;
      esac
    fi
    chmod +x "$RUNNER"

    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${RUNNER}</string>
    <string>${REPO_SLUG}</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>${HOME}</string>
    <key>PATH</key><string>${HOME}/.local/bin:${HOME}/.cargo/bin:${HOME}/.bun/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    <key>LASTGIT_SOCKET</key><string>${HOME}/.lastdb/data/folddb.sock</string>
    <key>LASTGIT_SCHEMA_MAP</key><string>${HOME}/.lastgit/schema-map.json</string>
    <key>LASTGIT_DEPLOY_CONTEXT</key><string>deploy-pipeline</string>
    <key>LASTGIT_DEPLOY_LOG_DIR</key><string>${LOG_DIR}</string>
    <key>AWS_PROFILE</key><string>${AWS_PROFILE:-default}</string>
    <key>SCHEMA_BUILD_REMOTE_HOST</key><string>${SCHEMA_BUILD_REMOTE_HOST:-pc}</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>StandardOutPath</key><string>${LOG_DIR}/launchd.log</string>
  <key>StandardErrorPath</key><string>${LOG_DIR}/launchd.log</string>
</dict>
</plist>
EOF

    launchctl bootout "${DOMAIN}/${LABEL}" 2>/dev/null || true
    # A label left disabled by an earlier `launchctl disable` rejects bootstrap
    # with an opaque "5: Input/output error" (this one sat disabled from
    # 2026-09-14 to 2026-09-21); enable BEFORE bootstrap. bootout is
    # asynchronous, so give the old instance a moment.
    launchctl enable "${DOMAIN}/${LABEL}" 2>/dev/null || true
    sleep 2
    launchctl bootstrap "$DOMAIN" "$PLIST"
    launchctl kickstart -k "${DOMAIN}/${LABEL}" 2>/dev/null || true

    echo "installed ${LABEL} -> ${RUNNER}"
    echo "  plist=${PLIST}"
    echo "  log_dir=${LOG_DIR}"
    ;;
  uninstall)
    launchctl bootout "${DOMAIN}/${LABEL}" 2>/dev/null || true
    rm -f "$PLIST"
    echo "unloaded ${LABEL}"
    ;;
  status)
    echo "expected deploy runner: ${RUNNER}"
    echo "expected lastgit socket: ${HOME}/.lastdb/data/folddb.sock"
    if [ -f "$PLIST" ]; then
      echo "installed plist:"
      plutil -p "$PLIST" 2>/dev/null | sed -n '1,100p' || true
    fi
    echo "launchd state:"
    launchctl print "${DOMAIN}/${LABEL}" 2>/dev/null | sed -n '1,80p' || echo "not loaded"
    echo "recent deploy log:"
    tail -20 "$LOG_DIR/deploy.log" 2>/dev/null || true
    ;;
  *)
    echo "usage: $0 install|uninstall|status" >&2
    exit 2
    ;;
esac
