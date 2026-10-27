#!/usr/bin/env bash
# Auto-rollback dev to previous-deployed-oid if smoke tests fail after CDK deploy.
# Prevents a bad re-land from leaving dev down.
set -euo pipefail

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

# Configure git auth via env vars (scoped to this script, nothing persisted)
# GH_PAT is provided by deploy.yml line 111 (dev) and line 198 (prod)
if [ -z "${GH_PAT:-}" ]; then
    echo "ERROR: GH_PAT not set; cannot fetch private submodule" >&2
    exit 1
fi

# Base64-encode the basic auth header for git (no global config, env-only)
# actions/checkout@v5 already saved an http.https://github.com/.extraheader in .git/config
# Clear it first (empty value) then add ours to avoid duplicate Authorization headers (GitHub 400)
GIT_AUTH_HEADER="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$GH_PAT" | base64 -w0)"
export GIT_CONFIG_COUNT=2
export GIT_CONFIG_KEY_0="http.https://github.com/.extraheader"
export GIT_CONFIG_VALUE_0=""
export GIT_CONFIG_KEY_1="http.https://github.com/.extraheader"
export GIT_CONFIG_VALUE_1="$GIT_AUTH_HEADER"

# Work in a separate worktree so the original checkout stays intact for artifact upload
WORKTREE_DIR="$(mktemp -d)"
trap 'rm -rf "$WORKTREE_DIR"' EXIT

echo "Creating rollback worktree at $WORKTREE_DIR"

# Fetch and create worktree at the rollback target
# Skip fetch if commit is already present (fetch-depth=0 in deploy.yml has all commits)
git cat-file -e "$ROLLBACK_TO^{commit}" 2>/dev/null || git fetch --depth=1 origin "$ROLLBACK_TO"
git worktree add "$WORKTREE_DIR" "$ROLLBACK_TO"

cd "$WORKTREE_DIR"

# Get the fold submodule pin from this commit
FOLD_PIN="$(git ls-tree HEAD fold | awk '{print $3}')"
if [ -z "$FOLD_PIN" ]; then
    echo "ERROR: Could not resolve fold submodule pin from $ROLLBACK_TO" >&2
    exit 1
fi

echo "Fold pin for rollback: $FOLD_PIN"

# Initialize fold submodule at the rolled-back commit's pin
# GIT_CONFIG_* env vars are already set above for auth
git submodule update --init --depth=1 fold
cd fold
git fetch --depth=1 origin "$FOLD_PIN"
git checkout "$FOLD_PIN"
cd ..

echo "Submodule fold checked out at $FOLD_PIN in worktree"

# Re-deploy dev from the worktree (deploy.sh already builds; no separate build.sh call)
# All paths (fold, build artifacts, etc.) resolve inside the worktree at the old pin
bash "$WORKTREE_DIR/deploy.sh" dev --yes

# Health check: verify dev /v1/health returns 200 before recording the rollback
HEALTH_URL="https://y0q3m6vk75.execute-api.us-west-2.amazonaws.com/v1/health"
HEALTH_TIMEOUT=30
HEALTH_RETRIES=5
HEALTH_OK=false

echo "Checking health endpoint $HEALTH_URL (retries: $HEALTH_RETRIES, timeout: ${HEALTH_TIMEOUT}s)"
for i in $(seq 1 $HEALTH_RETRIES); do
    if curl --silent --fail --max-time "$HEALTH_TIMEOUT" "$HEALTH_URL" > /dev/null 2>&1; then
        echo "Health check passed on attempt $i"
        HEALTH_OK=true
        break
    else
        echo "Health check failed on attempt $i, retrying..."
        sleep 2
    fi
done

if [ "$HEALTH_OK" = false ]; then
    echo "ERROR: Health check never recovered after rollback to $ROLLBACK_TO" >&2
    echo "Not recording rollback in last-deployed-oid; manual intervention required" >&2
    exit 1
fi

# Record the successful rollback in last-deployed-oid in the ORIGINAL STATE_DIR
# so the artifact upload reflects the actual deployed state
printf '%s\n' "$ROLLBACK_TO" > "$LAST_OID_FILE"

echo "Rollback to $ROLLBACK_TO complete and recorded in original STATE_DIR"
