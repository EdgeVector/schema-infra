#!/usr/bin/env bash
# Auto-rollback dev to last-deployed-oid if smoke tests fail after CDK deploy.
# Prevents a bad re-land from leaving dev down.
set -euo pipefail

ENVIRONMENT="${1:-dev}"
LAST_OID_FILE="${LASTGIT_DEPLOY_LOG_DIR}/last-deployed-oid"

if [ ! -f "$LAST_OID_FILE" ]; then
    echo "WARN: no last-deployed-oid found; cannot auto-rollback" >&2
    exit 0
fi

LAST_OID="$(head -1 "$LAST_OID_FILE" | tr -d '[:space:]')"
if [ -z "$LAST_OID" ]; then
    echo "WARN: last-deployed-oid is empty; cannot auto-rollback" >&2
    exit 0
fi

CURRENT_OID="$(git rev-parse HEAD)"
if [ "$CURRENT_OID" = "$LAST_OID" ]; then
    echo "Already at last-deployed oid $LAST_OID; nothing to roll back"
    exit 0
fi

echo "== Auto-rollback: reverting $ENVIRONMENT to last good deploy $LAST_OID =="
git fetch origin "$LAST_OID"
git checkout "$LAST_OID"

# Re-run the deploy with the last good commit
bash "$(dirname "$0")/../../deploy.sh" "$ENVIRONMENT" --skip-build

echo "Rollback to $LAST_OID complete"
