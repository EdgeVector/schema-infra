#!/usr/bin/env bash
# Shared helpers for schema-infra staged canary deploys (bash 3.2+).
# Sourced by deploy-pipeline.sh and canary-ticker.sh.
set -euo pipefail

CANARY_SOAK_HOURS="${CANARY_SOAK_HOURS:-24}"
CANARY_WEIGHT="${CANARY_WEIGHT:-0.1}"  # 10% of traffic ≈ "one box" for serverless
STATE_DIR="${LASTGIT_DEPLOY_LOG_DIR:-$HOME/.lastgit/deploy-schema-infra}"
STATE_FILE="${STATE_DIR}/canary-state.json"
mkdir -p "$STATE_DIR"

canary_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

canary_log() {
  echo "[$(canary_ts)] $*" | tee -a "${STATE_DIR}/canary.log"
}

# Resolve function name from CloudFormation stack.
schema_fn_name() {
  local env="$1" region="$2"
  aws cloudformation describe-stacks \
    --stack-name "SchemaServiceStack-${env}" \
    --region "$region" \
    --query 'Stacks[0].Outputs[?OutputKey==`SchemaServiceFunctionName`].OutputValue' \
    --output text 2>/dev/null | head -1
}

schema_api_url() {
  local env="$1" region="$2"
  aws cloudformation describe-stacks \
    --stack-name "SchemaServiceStack-${env}" \
    --region "$region" \
    --query 'Stacks[0].Outputs[?OutputKey==`SchemaServiceApiUrl`].OutputValue' \
    --output text 2>/dev/null | head -1
}

# Snapshot the current live alias version (stable version before deploy).
alias_version() {
  local fn="$1" region="$2"
  aws lambda get-alias \
    --function-name "$fn" \
    --name live \
    --region "$region" \
    --query 'FunctionVersion' \
    --output text 2>/dev/null || echo ""
}

# Code SHA-256 of one published version ("" if the version does not exist).
version_code_sha() {
  local fn="$1" region="$2" ver="$3"
  aws lambda get-function-configuration \
    --function-name "$fn" \
    --qualifier "$ver" \
    --region "$region" \
    --query 'CodeSha256' \
    --output text 2>/dev/null || true
}

version_exists() {
  local fn="$1" region="$2" ver="$3"
  aws lambda get-function --function-name "$fn:$ver" --region "$region" >/dev/null 2>&1
}

# After CDK points live → NEW 100%, re-pin: primary=OLD, 10% → NEW.
# OLD must be the version the live alias served BEFORE this deploy. It is the
# only safe primary: any other version is code nobody chose to serve now.
# Return codes:
#   0  weighted pin applied (primary=OLD, CANARY_WEIGHT → NEW)
#   1  no pin needed (no distinct prior version) — live stays where it is
#   2  REFUSED, fail closed: OLD no longer exists. The alias is NOT touched,
#      so live stays on whatever it serves now (100% NEW after a CDK deploy).
#      The caller must alert. Never substitute an older version: on
#      2026-09-23 that put 90% of prod on 2026-09-01 code.
set_canary_weights() {
  local fn="$1" region="$2" old_ver="$3" new_ver="$4"
  if [ -z "${new_ver:-}" ] || [ "$new_ver" = "None" ]; then
    canary_log "canary: no new version — skip pin"
    return 1
  fi
  if [ -z "$old_ver" ] || [ "$old_ver" = "$new_ver" ] || [ "$old_ver" = "\$LATEST" ] || [ "$old_ver" = "None" ]; then
    canary_log "canary: no prior version to weight (old=${old_ver:-none} new=$new_ver) — leaving 100% on new"
    return 1
  fi
  if ! version_exists "$fn" "$region" "$old_ver"; then
    canary_log "canary: REFUSED — pre-deploy live version old=$old_ver no longer exists; not pinning any other version; live alias left as is (new=$new_ver)"
    return 2
  fi
  # Weighted routing is incompatible with provisioned concurrency on the alias.
  if aws lambda get-provisioned-concurrency-config \
      --function-name "$fn" --qualifier live --region "$region" >/dev/null 2>&1; then
    canary_log "canary: dropping provisioned concurrency on live (required for weighted canary)"
    aws lambda delete-provisioned-concurrency-config \
      --function-name "$fn" --qualifier live --region "$region" >/dev/null 2>&1 || true
  fi
  canary_log "canary: pin primary=$old_ver canary=$new_ver weight=$CANARY_WEIGHT"
  aws lambda update-alias \
    --function-name "$fn" \
    --name live \
    --function-version "$old_ver" \
    --routing-config "AdditionalVersionWeights={${new_ver}=${CANARY_WEIGHT}}" \
    --region "$region" >/dev/null
  return 0
}

# Best-effort operator alert for a refused canary pin: a Situations notice
# (FYI timeline) plus stderr. Never fails the caller by itself.
canary_alert() {
  local summary="$1"
  echo "ALERT: $summary" >&2
  canary_log "ALERT: $summary"
  if command -v situations >/dev/null 2>&1 && [ "${SCHEMA_CANARY_ALERT_NOTICE:-1}" != "0" ]; then
    situations notice --title "schema-infra canary pin refused" --kind deploy \
      --system schema-service --actor script:schema-infra-canary \
      --summary "$summary" >/dev/null 2>&1 || true
  fi
}

# Promote canary version to 100% (must clear routing weights).
promote_canary_full() {
  local fn="$1" region="$2" new_ver="$3"
  [ -n "${new_ver:-}" ] || return 0
  canary_log "canary: promote 100% → version $new_ver (clear routing weights)"
  if ! aws lambda update-alias \
      --function-name "$fn" \
      --name live \
      --function-version "$new_ver" \
      --routing-config "AdditionalVersionWeights={}" \
      --region "$region" >/dev/null 2>&1; then
    aws lambda update-alias \
      --function-name "$fn" \
      --name live \
      --function-version "$new_ver" \
      --region "$region" >/dev/null
  fi
}

# Rollback: 100% to old version.
rollback_canary() {
  local fn="$1" region="$2" old_ver="$3"
  if ! version_exists "$fn" "$region" "$old_ver"; then
    canary_alert "canary ROLLBACK impossible: version $old_ver of $fn no longer exists; live alias left as is"
    return 1
  fi
  canary_log "canary: ROLLBACK 100% → version $old_ver"
  aws lambda update-alias \
    --function-name "$fn" \
    --name live \
    --function-version "$old_ver" \
    --region "$region" >/dev/null
}

# Write canary state JSON (python for portable JSON).
write_canary_state() {
  local oid="$1" old_ver="$2" new_ver="$3" fn="$4" region="$5" started="$6" promote_after="$7"
  python3 - "$STATE_FILE" "$oid" "$old_ver" "$new_ver" "$fn" "$region" "$started" "$promote_after" <<'PY'
import json, sys
path, oid, old, new, fn, region, started, promote = sys.argv[1:]
state = {
  "repo": "schema-infra",
  "oid": oid,
  "stage": "canary_soak",
  "old_version": old,
  "new_version": new,
  "function_name": fn,
  "region": region,
  "canary_started_at": started,
  "promote_after": promote,
  "weight": float(__import__("os").environ.get("CANARY_WEIGHT", "0.1")),
}
with open(path, "w") as f:
  json.dump(state, f, indent=2)
  f.write("\n")
print(path)
PY
}

clear_canary_state() {
  rm -f "$STATE_FILE"
}

# True if promote_after is in the past (UTC).
canary_soak_elapsed() {
  local promote_after="$1"
  python3 - "$promote_after" <<'PY'
import sys
from datetime import datetime, timezone
pa = sys.argv[1].replace("Z", "+00:00")
t = datetime.fromisoformat(pa)
now = datetime.now(timezone.utc)
sys.exit(0 if now >= t else 1)
PY
}

# Check CloudWatch alarms for the schema function (any ALARM → fail).
canary_alarms_ok() {
  local region="$1"
  # Production promotion must never degrade to a time-only gate. Operators
  # may override this set, but an empty/unset override still falls back to
  # the two alarms provisioned by SchemaServiceStack-prod.
  local names
  if [ -z "${SCHEMA_CANARY_ALARM_NAMES:-}" ]; then
    names="schema-mutation-gate-hourly-quota-prod schema-mutation-gate-internal-error-prod"
  else
    names="$SCHEMA_CANARY_ALARM_NAMES"
  fi
  local name state
  for name in $names; do
    state=$(aws cloudwatch describe-alarms --alarm-names "$name" --region "$region" \
      --query 'MetricAlarms[0].StateValue' --output text 2>/dev/null || echo "ERROR")
    canary_log "canary: alarm $name state=$state"
    case "$state" in
      OK|INSUFFICIENT_DATA) ;;
      *) return 1 ;;
    esac
  done
  return 0
}
