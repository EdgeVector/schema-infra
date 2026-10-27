#!/usr/bin/env bash
# Restore the last deployed git oid into $LASTGIT_DEPLOY_LOG_DIR/last-deployed-oid.
#
# Downloads the newest last-deployed-oid-{dev,prod} artifact from successful or
# failed runs (failed runs may have deployed successfully but failed smoke). Each
# environment has its own artifact and baseline to prevent dev-only deploys from
# becoming prod's classifier base. A missing artifact is not an error: the
# classifier then takes the conservative full path.
#
# Env:
#   DEPLOY_ENV               dev or prod (required)
#   LAST_DEPLOYED_OID_FILE   when set, copied instead of downloading (for tests)
set -euo pipefail

dir="${LASTGIT_DEPLOY_LOG_DIR:?LASTGIT_DEPLOY_LOG_DIR is required}"
env="${DEPLOY_ENV:?DEPLOY_ENV is required (dev or prod)}"
mkdir -p "$dir"
dest="$dir/last-deployed-oid"

if [ -n "${LAST_DEPLOYED_OID_FILE:-}" ]; then
  if [ -s "$LAST_DEPLOYED_OID_FILE" ]; then
    cp "$LAST_DEPLOYED_OID_FILE" "$dest"
    echo "restore-last-oid: copied fixture"
  else
    echo "restore-last-oid: fixture empty"
  fi
  exit 0
fi

if [ -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ] || ! command -v gh >/dev/null 2>&1; then
  echo "restore-last-oid: no GitHub token — no base oid"
  exit 0
fi

repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
current="${GITHUB_RUN_ID:-}"
artifact_name="last-deployed-oid-${env}"
ids="$(mktemp)"
# Check both successful and failed runs: a failed run may have deployed
# successfully but failed during smoke tests, leaving broken code live.
gh run list --repo "$repo" --workflow deploy.yml --branch main \
  --limit 30 --json databaseId,conclusion \
  --jq '.[] | select(.conclusion == "success" or .conclusion == "failure") | .databaseId' >"$ids"

while IFS= read -r id; do
  [ -z "$id" ] && continue
  if [ -n "$current" ] && [ "$id" = "$current" ]; then
    continue
  fi
  tmp="$(mktemp -d)"
  if gh run download "$id" --repo "$repo" --name "$artifact_name" --dir "$tmp" 2>/dev/null; then
    if [ -s "$tmp/last-deployed-oid" ]; then
      cp "$tmp/last-deployed-oid" "$dest"
      echo "restore-last-oid ($env): run $id"
      exit 0
    fi
  fi
done <"$ids"

echo "restore-last-oid ($env): no prior artifact"
exit 0
