#!/usr/bin/env bash
# Restore the last prod git oid into $LASTGIT_DEPLOY_LOG_DIR/last-deployed-oid.
#
# The Mac watcher kept this file under ~/.lastgit. A GitHub runner does not.
# The prod job uploads an artifact named last-deployed-oid. The next deploy
# downloads the newest successful one so classify-change.sh can skip a
# no-impact diff. A missing artifact is not an error: the classifier then
# takes the conservative full path.
#
# LAST_DEPLOYED_OID_FILE, when set, is copied and GitHub is not called.
set -euo pipefail

dir="${LASTGIT_DEPLOY_LOG_DIR:?LASTGIT_DEPLOY_LOG_DIR is required}"
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
ids="$(mktemp)"
gh run list --repo "$repo" --workflow deploy.yml --branch main --status success \
  --limit 20 --json databaseId --jq '.[].databaseId' >"$ids"

while IFS= read -r id; do
  [ -z "$id" ] && continue
  if [ -n "$current" ] && [ "$id" = "$current" ]; then
    continue
  fi
  tmp="$(mktemp -d)"
  if gh run download "$id" --repo "$repo" --name last-deployed-oid --dir "$tmp"; then
    if [ -s "$tmp/last-deployed-oid" ]; then
      cp "$tmp/last-deployed-oid" "$dest"
      echo "restore-last-oid: run $id"
      exit 0
    fi
  fi
done <"$ids"

echo "restore-last-oid: no prior artifact"
exit 0
