#!/usr/bin/env bash
# Staged deploy pipeline for schema-infra (LastGit context: deploy-pipeline).
#
# Stages:
#   1. Deploy DEV (us-west-2)
#   2. Smoke tests on DEV
#   3. Deploy PROD code + pin ~10% traffic on new version ("one box" canary)
#   4. Smoke PROD
#   5. Record soak state — canary-ticker promotes to 100% after CANARY_SOAK_HOURS (default 24)
#      only if configured alarms stay non-ALARM
#
# Env:
#   DEPLOY_FREEZE=true           skip all
#   LASTGIT_DEPLOY_SKIP_PROD=1   stop after successful dev smoke
#   CANARY_SOAK_HOURS=24         canary soak duration
#   CANARY_WEIGHT=0.1            fraction of prod traffic on new version
#   SCHEMA_CANARY_ALARM_NAMES    optional override; defaults to the required
#                                production mutation-gate alarm set
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/deploy/canary-lib.sh
source "$(pwd)/scripts/deploy/canary-lib.sh"

OID="${LASTGIT_CI_OID:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}"
echo "== [schema staged-deploy] oid=$OID =="

if [ "${DEPLOY_FREEZE:-}" = "true" ]; then
  echo "DEPLOY_FREEZE=true — skip"
  exit 0
fi

command -v aws >/dev/null || { echo "FAIL: aws missing" >&2; exit 1; }
command -v curl >/dev/null || { echo "FAIL: curl missing" >&2; exit 1; }
aws sts get-caller-identity --query Account --output text >/dev/null
echo "AWS identity OK"

if [ -f .gitmodules ] && [ "${LASTGIT_DEPLOY_SKIP_SUBMODULE:-}" != "1" ]; then
  git submodule update --init --recursive
fi

# ---------- 1. DEV deploy ----------
echo "== STAGE 1: deploy DEV =="
export AWS_REGION=us-west-2 AWS_DEFAULT_REGION=us-west-2
./deploy.sh dev --yes

# ---------- 2. DEV smoke ----------
echo "== STAGE 2: smoke DEV =="
bash ./scripts/deploy/smoke-dev.sh

if [ "${LASTGIT_DEPLOY_SKIP_PROD:-}" = "1" ] || [ "${LASTGIT_DEPLOY_SKIP_PROD:-}" = "true" ]; then
  echo "LASTGIT_DEPLOY_SKIP_PROD — stop after dev smoke"
  echo "lastgit schema deploy-pipeline PASSED (dev only)"
  exit 0
fi

# ---------- 3. PROD deploy + canary pin ----------
echo "== STAGE 3: deploy PROD + canary pin =="
export AWS_REGION=us-east-1 AWS_DEFAULT_REGION=us-east-1

FN=$(schema_fn_name prod us-east-1 || true)
OLD_VER=""
if [ -n "${FN:-}" ] && [ "$FN" != "None" ]; then
  OLD_VER=$(alias_version "$FN" us-east-1 || true)
  canary_log "pre-prod alias version old=${OLD_VER:-none} fn=$FN"
fi

./deploy.sh prod --yes

echo "== STAGE 4: smoke PROD =="
bash ./scripts/deploy/smoke-dev.sh prod

FN=$(schema_fn_name prod us-east-1)
NEW_VER=$(alias_version "$FN" us-east-1)
canary_log "post-prod alias version new=$NEW_VER fn=$FN"

# Re-pin 10% canary if we had a prior version; only write soak state when pin lands.
if set_canary_weights "$FN" us-east-1 "${OLD_VER:-}" "$NEW_VER"; then
  STARTED=$(canary_ts)
  export CANARY_SOAK_HOURS="${CANARY_SOAK_HOURS:-24}"
  PROMOTE_AFTER=$(python3 - <<PY
from datetime import datetime, timedelta, timezone
import os
h = float(os.environ.get("CANARY_SOAK_HOURS", "24"))
print((datetime.now(timezone.utc) + timedelta(hours=h)).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
)
  write_canary_state "$OID" "${OLD_VER:-}" "$NEW_VER" "$FN" "us-east-1" "$STARTED" "$PROMOTE_AFTER"
  canary_log "canary soak until $PROMOTE_AFTER (CANARY_SOAK_HOURS=${CANARY_SOAK_HOURS})"
  echo "lastgit schema deploy-pipeline PASSED (prod canary soaking until $PROMOTE_AFTER)"
  echo "Promote via: .lastgit/canary-ticker.sh (launchd) or manual scripts/deploy promote"
else
  clear_canary_state 2>/dev/null || rm -f "${STATE_FILE:-}"
  canary_log "canary: no weighted pin (old==new or missing) — no soak state"
  echo "lastgit schema deploy-pipeline PASSED (prod deploy; no canary pin needed)"
fi
