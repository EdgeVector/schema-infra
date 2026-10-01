#!/usr/bin/env bash
# restore-last-oid.sh copies a fixture and, with a fake gh, the newest artifact.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/deploy/restore-last-oid.sh"
test -f "$SCRIPT" || { echo "missing $SCRIPT" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 1. Explicit fixture. gh must not run.
printf '%s\n' abcdef >"$TMP/oid"
cat >"$TMP/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh must not run for a fixture" >&2
exit 9
EOF
chmod +x "$TMP/gh"
PATH="$TMP:$PATH" \
  LASTGIT_DEPLOY_LOG_DIR="$TMP/state1" \
  LAST_DEPLOYED_OID_FILE="$TMP/oid" \
  GH_TOKEN=x GITHUB_REPOSITORY=EdgeVector/schema-infra \
  bash "$SCRIPT" >/dev/null
got="$(tr -d '[:space:]' <"$TMP/state1/last-deployed-oid")"
[ "$got" = "abcdef" ] || { echo "fixture copy failed: $got" >&2; exit 1; }

# 2. Fake gh: skip the current run, take the next artifact.
cat >"$TMP/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "run" ] && [ "$2" = "list" ]; then
  printf '%s\n' 111 222
  exit 0
fi
if [ "$1" = "run" ] && [ "$2" = "download" ]; then
  id="$3"
  dir=""
  prev=""
  for a in "$@"; do
    if [ "$prev" = "--dir" ]; then
      dir="$a"
    fi
    prev="$a"
  done
  if [ "$id" = "222" ]; then
    printf '%s\n' deadbeef >"$dir/last-deployed-oid"
    exit 0
  fi
  exit 1
fi
echo "unexpected gh: $*" >&2
exit 9
EOF
chmod +x "$TMP/gh"
PATH="$TMP:$PATH" \
  LASTGIT_DEPLOY_LOG_DIR="$TMP/state2" \
  GH_TOKEN=x GITHUB_REPOSITORY=EdgeVector/schema-infra GITHUB_RUN_ID=111 \
  bash "$SCRIPT" >/dev/null
got="$(tr -d '[:space:]' <"$TMP/state2/last-deployed-oid")"
[ "$got" = "deadbeef" ] || { echo "artifact restore failed: $got" >&2; exit 1; }

# 3. No token: success, no file. Drop any token the parent shell inherited.
env -u GH_TOKEN -u GITHUB_TOKEN LASTGIT_DEPLOY_LOG_DIR="$TMP/state3" bash "$SCRIPT" >/dev/null
if [ -e "$TMP/state3/last-deployed-oid" ]; then
  echo "expected no oid file without a token" >&2
  exit 1
fi
echo "ok restore-last-oid"
