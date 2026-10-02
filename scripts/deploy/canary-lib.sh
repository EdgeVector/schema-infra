#!/usr/bin/env bash
# Shared helpers for schema-infra staged canary deploys (bash 3.2+).
# Sourced by deploy-pipeline.sh and canary-ticker.sh.
set -euo pipefail

CANARY_SOAK_HOURS="${CANARY_SOAK_HOURS:-24}"
CANARY_WEIGHT="${CANARY_WEIGHT:-0.05}"  # 5% of live prod traffic on the new version
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

# After CDK points live → NEW 100%, re-pin: primary=OLD, CANARY_WEIGHT → NEW.
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

# Rollback: 100% to old version, and clear AdditionalVersionWeights.
# AWS update-alias keeps the current routing config when --routing-config is
# omitted, so a 5% canary would stay on the new version. Always write an
# empty weight map. Do not fall back to a call that leaves weights in place.
rollback_canary() {
  local fn="$1" region="$2" old_ver="$3"
  if ! version_exists "$fn" "$region" "$old_ver"; then
    canary_alert "canary ROLLBACK impossible: version $old_ver of $fn no longer exists; live alias left as is"
    return 1
  fi
  canary_log "canary: ROLLBACK 100% → version $old_ver (clear routing weights)"
  aws lambda update-alias \
    --function-name "$fn" \
    --name live \
    --function-version "$old_ver" \
    --routing-config "AdditionalVersionWeights={}" \
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
  "weight": float(__import__("os").environ.get("CANARY_WEIGHT", "0.05")),
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

# The two prod mutation-gate alarms are the only abort signals. Operators
# may override the set, but an empty/unset override still falls back here.
canary_alarm_names() {
  if [ -z "${SCHEMA_CANARY_ALARM_NAMES:-}" ]; then
    printf '%s\n' "schema-mutation-gate-hourly-quota-prod schema-mutation-gate-internal-error-prod"
  else
    printf '%s\n' "$SCHEMA_CANARY_ALARM_NAMES"
  fi
}

canary_alarm_state() {
  local region="$1" name="$2"
  aws cloudwatch describe-alarms --alarm-names "$name" --region "$region" \
    --query 'MetricAlarms[0].StateValue' --output text 2>/dev/null || echo "ERROR"
}

# True when every configured alarm exists and CloudWatch returns a real state.
# ALARM is a present state. None/ERROR/empty is missing. A missing name must
# fail the tick and must not change the alias.
canary_alarms_present() {
  local region="$1"
  local names name state
  names="$(canary_alarm_names)"
  for name in $names; do
    state="$(canary_alarm_state "$region" "$name")"
    canary_log "canary: alarm $name state=$state"
    case "$state" in
      OK|INSUFFICIENT_DATA|ALARM) ;;
      *) return 1 ;;
    esac
  done
  return 0
}

# Print each configured alarm currently in ALARM, one name per line.
canary_firing_alarms() {
  local region="$1"
  local names name state
  names="$(canary_alarm_names)"
  for name in $names; do
    state="$(canary_alarm_state "$region" "$name")"
    if [ "$state" = "ALARM" ]; then
      printf '%s\n' "$name"
    fi
  done
}

# Check CloudWatch alarms for promotion (any ALARM or missing → fail).
canary_alarms_ok() {
  local region="$1"
  canary_alarms_present "$region" || return 1
  if [ -n "$(canary_firing_alarms "$region")" ]; then
    return 1
  fi
  return 0
}

# Write the four rollback fields to the Actions job summary when the
# Issues API call fails. The alias change already happened.
canary_rollback_issue_fallback() {
  local alarm="$1" fn="$2" old="$3" new="$4" reason="$5"
  canary_log "canary: issue fallback ($reason) alarm=$alarm function=$fn old=$old new=$new"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "## schema-canary-rollback"
      echo "alarm: $alarm"
      echo "function: $fn"
      echo "old: $old"
      echo "new: $new"
    } >> "$GITHUB_STEP_SUMMARY"
  fi
}

# Open one GitHub issue after a successful alias abort. Never fails the
# caller: the tick already changed the alias and must still exit non-zero.
canary_open_rollback_issue() {
  local alarm="$1" fn="$2" old="$3" new="$4"
  local repo title body_file
  repo="${GITHUB_REPOSITORY:-EdgeVector/schema-infra}"
  title="schema-canary-rollback ${fn} ${old} ${new}"
  body_file="${STATE_DIR}/rollback-issue-body.txt"
  cat >"$body_file" <<EOF
alarm: ${alarm}
function: ${fn}
old: ${old}
new: ${new}
EOF
  canary_log "canary: opening GitHub issue $title"
  if [ -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ] || ! command -v gh >/dev/null 2>&1; then
    canary_rollback_issue_fallback "$alarm" "$fn" "$old" "$new" "gh missing or unauthenticated"
    return 0
  fi
  gh label create schema-canary-rollback \
    --repo "$repo" \
    --description "Schema live alias canary rollback" \
    --color "CCCCCC" >/dev/null 2>&1 || true
  if ! gh issue create \
      --repo "$repo" \
      --title "$title" \
      --label schema-canary-rollback \
      --body-file "$body_file" >/dev/null 2>&1; then
    canary_rollback_issue_fallback "$alarm" "$fn" "$old" "$new" "gh issue create failed"
    return 0
  fi
  canary_log "canary: rollback issue opened"
  return 0
}

# Plan one live alias from its routing config and LastModified.
# stdout is one line:
#   idle
#   soaking <TAB> old <TAB> new <TAB> promote_after
#   due     <TAB> old <TAB> new <TAB> promote_after
# A weight other than CANARY_WEIGHT is idle. Another writer owns that shift.
# CANARY_ALIAS_FIXTURE, when set, is a get-alias JSON file (tests).
# CANARY_NOW overrides the clock (UTC, ISO-8601).
canary_alias_plan() {
  local fn="$1" region="$2" json
  if [ -n "${CANARY_ALIAS_FIXTURE:-}" ]; then
    json="$(cat "$CANARY_ALIAS_FIXTURE")"
  else
    json="$(aws lambda get-alias --function-name "$fn" --name live --region "$region" --output json 2>/dev/null || true)"
  fi
  [ -n "${json:-}" ] || { printf '%s\n' idle; return 0; }
  # The heredoc is python's stdin, so the alias JSON goes in argv.
  CANARY_SOAK_HOURS="$CANARY_SOAK_HOURS" CANARY_WEIGHT="$CANARY_WEIGHT" CANARY_NOW="${CANARY_NOW:-}" \
    python3 - "$json" <<'PY'
import json, os, sys
from datetime import datetime, timedelta, timezone

raw = sys.argv[1]
try:
    alias = json.loads(raw)
except Exception:
    print("idle")
    raise SystemExit(0)
weights = ((alias.get("RoutingConfig") or {}).get("AdditionalVersionWeights") or {})
if len(weights) == 0:
    print("idle")
    raise SystemExit(0)
if len(weights) != 1:
    print("bad_shape")
    raise SystemExit(0)
new, weight = next(iter(weights.items()))
want = float(os.environ.get("CANARY_WEIGHT", "0.05"))
if abs(float(weight) - want) > 0.001:
    print("bad_shape")
    raise SystemExit(0)
old = str(alias.get("FunctionVersion") or "")
if not old or old in ("$LATEST", "None") or old == str(new):
    print("idle")
    raise SystemExit(0)
started = str(alias.get("LastModified") or "")
s = started.replace("Z", "+00:00")
if s.endswith("+0000"):
    s = s[:-5] + "+00:00"
try:
    t0 = datetime.fromisoformat(s)
except Exception:
    print("idle")
    raise SystemExit(0)
if t0.tzinfo is None:
    t0 = t0.replace(tzinfo=timezone.utc)
hours = float(os.environ.get("CANARY_SOAK_HOURS", "24"))
promote = t0 + timedelta(hours=hours)
now_s = os.environ.get("CANARY_NOW") or ""
if now_s:
    now = datetime.fromisoformat(now_s.replace("Z", "+00:00"))
    if now.tzinfo is None:
        now = now.replace(tzinfo=timezone.utc)
else:
    now = datetime.now(timezone.utc)
promote_s = promote.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
action = "due" if now >= promote else "soaking"
print("%s\t%s\t%s\t%s" % (action, old, new, promote_s))
PY
}

# Live alias FunctionVersion (the rollback target). Empty when get-alias fails.
canary_alias_primary() {
  local fn="$1" region="$2" json
  if [ -n "${CANARY_ALIAS_FIXTURE:-}" ]; then
    json="$(cat "$CANARY_ALIAS_FIXTURE")"
  else
    json="$(aws lambda get-alias --function-name "$fn" --name live --region "$region" --output json 2>/dev/null || true)"
  fi
  [ -n "${json:-}" ] || return 0
  python3 - "$json" <<'PY'
import json, sys
try:
    alias = json.loads(sys.argv[1])
except Exception:
    raise SystemExit(0)
print(alias.get("FunctionVersion") or "")
PY
}

# GitHub ticker path. The live alias is the soak record: primary is the
# previous version, AdditionalVersionWeights at CANARY_WEIGHT is the new
# version, and LastModified plus CANARY_SOAK_HOURS is the promote time.
# A runner-local canary-state.json does not survive the job.
#
# Abort order (design): describe both alarms first; a missing name fails
# before any alias mutation; empty weights exit 0; any other weight map
# fails; a deleted FunctionVersion fails; ALARM plus a valid canary rolls
# the alias back, opens one GitHub issue, and exits non-zero.
tick_alias_canaries() {
  local region fn plan action old new promote primary firing alarm
  if [ "${DEPLOY_FREEZE:-}" = "true" ]; then
    canary_log "ticker: DEPLOY_FREEZE — leave canary as-is"
    return 0
  fi
  region="${CANARY_ALIAS_REGION:-us-east-1}"
  if [ -n "${CANARY_ALIAS_FN:-}" ]; then
    fn="$CANARY_ALIAS_FN"
  else
    fn="$(schema_fn_name prod "$region" || true)"
  fi
  if [ -z "${fn:-}" ] || [ "$fn" = "None" ]; then
    canary_log "ticker: no prod function"
    return 0
  fi
  if ! canary_alarms_present "$region"; then
    canary_log "ticker: required alarm missing — move no alias"
    return 1
  fi
  primary="$(canary_alias_primary "$fn" "$region" || true)"
  if [ -n "${primary:-}" ] && [ "$primary" != "None" ] && [ "$primary" != "\$LATEST" ]; then
    if ! version_exists "$fn" "$region" "$primary"; then
      canary_log "ticker: FunctionVersion $primary deleted — move no alias"
      return 1
    fi
  fi
  plan="$(canary_alias_plan "$fn" "$region")"
  IFS="$(printf '\t')" read -r action old new promote <<EOF
$plan
EOF
  case "$action" in
    idle)
      canary_log "ticker: no staged canary on $fn"
      return 0
      ;;
    bad_shape)
      canary_log "ticker: alias weight map is not empty and not one key at $CANARY_WEIGHT — move no alias"
      return 1
      ;;
    soaking|due) ;;
    *)
      canary_log "ticker: no staged canary on $fn"
      return 0
      ;;
  esac
  firing="$(canary_firing_alarms "$region" || true)"
  if [ -n "$firing" ]; then
    alarm="$(printf '%s\n' "$firing" | head -n 1)"
    canary_log "ticker: ALARM $alarm — rolling back $fn to $old"
    rollback_canary "$fn" "$region" "$old" || return 1
    canary_open_rollback_issue "$alarm" "$fn" "$old" "$new"
    return 1
  fi
  if [ "$action" = "due" ]; then
    promote_canary_full "$fn" "$region" "$new"
    canary_log "ticker: PROMOTED $fn to 100% version=$new"
    return 0
  fi
  canary_log "ticker: $fn still soaking until $promote (primary=$old canary=$new)"
  return 0
}
