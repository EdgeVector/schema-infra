#!/usr/bin/env bash
# Install continuous LastGit → GitHub public mirror for schema-infra.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LABEL=com.edgevector.lastgit-mirror-schema-infra
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOGDIR="$HOME/.lastgit/mirror-schema-infra"
WRAPPER="$LOGDIR/sync.sh"
mkdir -p "$LOGDIR"

# Durable wrapper (does not depend on a worktree path)
cat > "$WRAPPER" <<'WRAP'
#!/usr/bin/env bash
set -euo pipefail
export LASTGIT_SOCKET="${LASTGIT_SOCKET:-$HOME/.lastdb/data/folddb.sock}"
export LASTGIT_SCHEMA_MAP="${LASTGIT_SCHEMA_MAP:-$HOME/.lastgit/schema-map.json}"
export PATH="$HOME/.local/bin:$HOME/.bun/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
export LASTGIT_MIRROR_CLONE="${LASTGIT_MIRROR_CLONE:-$HOME/.lastgit/mirror-clones/schema-infra}"
export LASTGIT_MIRROR_REMOTE_URL="${LASTGIT_MIRROR_REMOTE_URL:-https://github.com/EdgeVector/schema-infra.git}"
export LASTGIT_MIRROR_SOURCE_URL="${LASTGIT_MIRROR_SOURCE_URL:-lastdb:///schema-infra}"
export LASTGIT_MIRROR_SOURCE_REMOTE=lastgit
export LASTGIT_MIRROR_REMOTE=origin
export LASTGIT_MIRROR_INTERVAL="${LASTGIT_MIRROR_INTERVAL:-60}"

if [ ! -d "$LASTGIT_MIRROR_CLONE/.git" ]; then
  mkdir -p "$(dirname "$LASTGIT_MIRROR_CLONE")"
  git -c lastgit.socket="$LASTGIT_SOCKET" clone -q "$LASTGIT_MIRROR_SOURCE_URL" "$LASTGIT_MIRROR_CLONE"
  git -C "$LASTGIT_MIRROR_CLONE" config lastgit.socket "$LASTGIT_SOCKET"
  if git -C "$LASTGIT_MIRROR_CLONE" remote get-url origin >/dev/null 2>&1; then
    git -C "$LASTGIT_MIRROR_CLONE" remote set-url origin "$LASTGIT_MIRROR_REMOTE_URL"
  else
    git -C "$LASTGIT_MIRROR_CLONE" remote add origin "$LASTGIT_MIRROR_REMOTE_URL"
  fi
  if ! git -C "$LASTGIT_MIRROR_CLONE" remote get-url lastgit >/dev/null 2>&1; then
    git -C "$LASTGIT_MIRROR_CLONE" remote add lastgit "$LASTGIT_MIRROR_SOURCE_URL"
  fi
fi

MODE="${1:-}"
MIRROR_DRIVER="${LASTGIT_MIRROR_DRIVER:-$HOME/code/edgevector/lastgit/.lastgit/sync-github-mirror.sh}"
exec "$MIRROR_DRIVER" schema-infra $MODE
WRAP
chmod +x "$WRAPPER"

# Prefer durable wrapper; keep repo script for manual use
cp -f "$ROOT/.lastgit/sync-github-mirror.sh" "$LOGDIR/repo-sync-github-mirror.sh" 2>/dev/null || true

cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$WRAPPER</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>$HOME</string>
    <key>PATH</key><string>$HOME/.local/bin:$HOME/.bun/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    <key>LASTGIT_SOCKET</key><string>$HOME/.lastdb/data/folddb.sock</string>
    <key>LASTGIT_SCHEMA_MAP</key><string>$HOME/.lastgit/schema-map.json</string>
    <key>LASTGIT_MIRROR_INTERVAL</key><string>60</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>StandardOutPath</key><string>$LOGDIR/launchd.log</string>
  <key>StandardErrorPath</key><string>$LOGDIR/launchd.log</string>
</dict>
</plist>
PL

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl unload "$PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl load -w "$PLIST"
launchctl enable "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl kickstart -k "gui/$(id -u)/$LABEL" 2>/dev/null || true
echo "installed $LABEL → $WRAPPER"
