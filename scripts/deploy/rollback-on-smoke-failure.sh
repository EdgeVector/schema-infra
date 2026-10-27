#!/usr/bin/env bash
# Auto-rollback dev to last-deployed-oid if smoke tests fail after CDK deploy.
# Prevents a bad re-land from leaving dev down.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENVIRONMENT="${1:-dev}"
LAST_OID_FILE="${LASTGIT_DEPLOY_LOG_DIR}/last-deployed-oid"

# NEVER touch prod - this is dev-only safety net
if [ "$ENVIRONMENT" != "dev" ]; then
    echo "ERROR: rollback-on-smoke-failure only runs on dev, not $ENVIRONMENT" >&2
    exit 1
fi

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

echo "== Auto-rollback: reverting dev to last good deploy $LAST_OID =="
git fetch origin "$LAST_OID"
git checkout "$LAST_OID"

# Update submodules to match the last good commit
git submodule update --init --recursive

# Rebuild the Lambda from the last good fold pin
bash "$SCRIPT_DIR/../../build.sh" dev-release

# Re-deploy with the freshly built artifact
bash "$SCRIPT_DIR/../../deploy.sh" dev

echo "Rollback to $LAST_OID complete"
