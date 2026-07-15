#!/usr/bin/env bash
# Install launchd agent that runs canary-ticker every 15 minutes.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="com.edgevector.lastgit-canary-ticker-schema-infra"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
LOG_DIR="${LASTGIT_DEPLOY_LOG_DIR:-$HOME/.lastgit/deploy-schema-infra}"
mkdir -p "$LOG_DIR" "$HOME/Library/LaunchAgents"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${REPO_ROOT}/.lastgit/canary-ticker.sh</string>
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
