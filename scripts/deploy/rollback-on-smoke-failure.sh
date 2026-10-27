#!/usr/bin/env bash
# Auto-rollback dev to previous-deployed-oid if smoke tests fail after CDK deploy.
# Prevents a bad re-land from leaving dev down.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENVIRONMENT="${1:-dev}"
PREVIOUS_OID_FILE="${LASTGIT_DEPLOY_LOG_DIR}/previous-deployed-oid"
LAST_OID_FILE="${LASTGIT_DEPLOY_LOG_DIR}/last-deployed-oid"

# NEVER touch prod - this is dev-only safety net
if [ "$ENVIRONMENT" != "dev" ]; then
    echo "ERROR: rollback-on-smoke-failure only runs on dev, not $ENVIRONMENT" >&2
    exit 1
fi

if [ ! -f "$PREVIOUS_OID_FILE" ]; then
    echo "WARN: no previous-deployed-oid found; cannot auto-rollback" >&2
    echo "This is expected on the first deploy to a new environment" >&2
    exit 0
fi

ROLLBACK_TO="$(head -1 "$PREVIOUS_OID_FILE" | tr -d '[:space:]')"
if [ -z "$ROLLBACK_TO" ]; then
    echo "WARN: previous-deployed-oid is empty; cannot auto-rollback" >&2
    exit 0
fi

CURRENT_OID="$(git rev-parse HEAD)"
if [ "$CURRENT_OID" = "$ROLLBACK_TO" ]; then
    echo "Already at rollback target $ROLLBACK_TO; nothing to roll back"
    exit 0
fi

echo "== Auto-rollback: reverting dev from $CURRENT_OID to last good deploy $ROLLBACK_TO =="

# Fetch the old commit explicitly for shallow checkout compatibility
git fetch --depth=1 origin "$ROLLBACK_TO"
git checkout "$ROLLBACK_TO"

# Get the fold submodule pin from this commit
FOLD_PIN="$(git ls-tree HEAD fold | awk '{print $3}')"
if [ -z "$FOLD_PIN" ]; then
    echo "ERROR: Could not resolve fold submodule pin from $ROLLBACK_TO" >&2
    exit 1
fi

echo "Fold pin for rollback: $FOLD_PIN"

# Initialize fold submodule at the rolled-back commit's pin
# Use the same credentials as the main checkout (GH_PAT env var)
if [ -n "${GH_PAT:-}" ]; then
    git config --global url."https://x-access-token:${GH_PAT}@github.com/".insteadOf "https://github.com/"
fi

git submodule update --init --depth=1 fold
cd fold
git fetch --depth=1 origin "$FOLD_PIN"
git checkout "$FOLD_PIN"
cd ..

echo "Submodule fold checked out at $FOLD_PIN"

# Rebuild the Lambda from the rolled-back fold pin
bash "$SCRIPT_DIR/../../build.sh" dev-release

# Re-deploy dev with the freshly built artifact
bash "$SCRIPT_DIR/../../deploy.sh" dev --yes

# Record the successful rollback in last-deployed-oid so the artifact upload is correct
printf '%s\n' "$ROLLBACK_TO" > "$LAST_OID_FILE"

echo "Rollback to $ROLLBACK_TO complete and recorded in last-deployed-oid"
