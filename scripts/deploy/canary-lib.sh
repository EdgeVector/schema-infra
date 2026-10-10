#!/usr/bin/env bash
# Shared helpers for schema-infra staged canary deploys (bash 3.2+).
# Sourced by deploy-pipeline.sh and canary-ticker.sh.
set -euo pipefail

CANARY_SOAK_HOURS="${CANARY_SOAK_HOURS:-24}"
CANARY_WEIGHT="${CANARY_WEIGHT:-0.05}"  # 5% of live prod traffic on the new version
STATE_DIR="${LASTGIT_DEPLOY_LOG_DIR:-$HOME/.lastgit/deploy-schema-infra}"
STATE_FILE="${STATE_DIR}/canary-state.json"
CANARY_ALIAS_HELPER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/canary-alias-state.py"
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
#   3  REFUSED: alias read, clock proof, or revision-checked update failed.
set_canary_weights() {
  local fn="$1" region="$2" old_ver="$3" new_ver="$4" alias_file request_file
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
  alias_file="$(mktemp "${TMPDIR:-/tmp}/schema-canary-alias.XXXXXX")"
  request_file="$(mktemp "${TMPDIR:-/tmp}/schema-canary-pin.XXXXXX")"
  if ! aws lambda get-alias --function-name "$fn" --name live --region "$region" \
      --output json > "$alias_file"; then
    canary_log "canary: REFUSED — cannot read the live alias before the pin"
    return 3
  fi
  if ! python3 "$CANARY_ALIAS_HELPER" stage --function-name "$fn" \
      --old "$old_ver" --new "$new_ver" --weight "$CANARY_WEIGHT" \
      < "$alias_file" > "$request_file"; then
    canary_log "canary: REFUSED — cannot store the clock and version proof; alias unchanged"
    return 3
  fi
  # Weighted routing is incompatible with provisioned concurrency on the alias.
  if aws lambda get-provisioned-concurrency-config \
      --function-name "$fn" --qualifier live --region "$region" >/dev/null 2>&1; then
    canary_log "canary: dropping provisioned concurrency on live (required for weighted canary)"
    aws lambda delete-provisioned-concurrency-config \
      --function-name "$fn" --qualifier live --region "$region" >/dev/null 2>&1 || true
  fi
  canary_log "canary: pin primary=$old_ver canary=$new_ver weight=$CANARY_WEIGHT with durable clock"
  if ! aws lambda update-alias --cli-input-json "file://$request_file" \
      --region "$region" >/dev/null; then
    canary_log "canary: REFUSED — alias revision changed or AWS rejected the pin"
    return 3
  fi
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
  local fn="$1" region="$2" new_ver="$3" revision="${4:-}"
  local revision_args=()
  [ -n "${new_ver:-}" ] || return 1
  [ -z "$revision" ] || revision_args=(--revision-id "$revision")
  canary_log "canary: promote 100% → version $new_ver (clear routing weights)"
  aws lambda update-alias \
    --function-name "$fn" \
    --name live \
    --function-version "$new_ver" \
    --routing-config "AdditionalVersionWeights={}" \
    "${revision_args[@]}" --region "$region" >/dev/null
}

# Rollback: FunctionVersion stays the old version. Clear AdditionalVersionWeights.
# AWS keeps the current routing config when --routing-config is omitted, so a
# 5% canary would stay on the new version. Always write an empty weight map.
# Do not set FunctionVersion to the 0.05 key. Do not add a 0.95 weight key.
# Do not pick a predecessor from list-versions-by-function.
rollback_canary() {
  local fn="$1" region="$2" old_ver="$3" revision="${4:-}"
  local revision_args=()
  [ -z "$revision" ] || revision_args=(--revision-id "$revision")
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
    "${revision_args[@]}" --region "$region" >/dev/null
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

canary_default_alarm_names() {
  if [ -z "${SCHEMA_CANARY_ALARM_NAMES:-}" ]; then
    printf '%s\n' "schema-mutation-gate-hourly-quota-prod schema-mutation-gate-internal-error-prod"
  else
    printf '%s\n' "$SCHEMA_CANARY_ALARM_NAMES"
  fi
}

canary_rollback_fields() {
  printf 'alarm: %s\nfunction: %s\nold: %s\nnew: %s\n' "$1" "$2" "$3" "$4"
}

canary_rollback_summary() {
  local bodyf="$1"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    cat "$bodyf" >> "$GITHUB_STEP_SUMMARY"
  fi
}

# After a successful alias abort, open one GitHub issue. The ubuntu ticker
# cannot open folddb.sock, so it never calls kanban. SCHEMA_CANARY_OPEN_ISSUE=1
# (set by canary-ticker.yml) enables the hop. Tests leave it unset unless they
# cover the issue path. If gh fails, write the four fields to
# GITHUB_STEP_SUMMARY and return 1.
open_canary_rollback_issue() {
  local alarm="$1" fn="$2" old="$3" new="$4"
  local repo title bodyf gh_bin
  if [ "${SCHEMA_CANARY_OPEN_ISSUE:-0}" != "1" ]; then
    canary_log "canary: skip GitHub issue (SCHEMA_CANARY_OPEN_ISSUE!=1)"
    return 0
  fi
  repo="${SCHEMA_CANARY_ISSUE_REPO:-${GITHUB_REPOSITORY:-EdgeVector/schema-infra}}"
  title="schema-canary-rollback ${fn} ${old} ${new}"
  bodyf="$(mktemp "${TMPDIR:-/tmp}/schema-canary-issue.XXXXXX")"
  canary_rollback_fields "$alarm" "$fn" "$old" "$new" >"$bodyf"
  if [ -n "${CANARY_GH:-}" ]; then
    gh_bin="$CANARY_GH"
  elif command -v gh >/dev/null 2>&1; then
    gh_bin="gh"
  else
    gh_bin=""
  fi
  if [ -z "$gh_bin" ] || { [ ! -x "$gh_bin" ] && ! command -v "$gh_bin" >/dev/null 2>&1; }; then
    canary_log "canary: gh missing — writing rollback fields to job summary"
    canary_rollback_summary "$bodyf"
    return 1
  fi
  "$gh_bin" label create schema-canary-rollback --repo "$repo" \
    --description "Prod schema live canary abort" --color B60205 >/dev/null 2>&1 || true
  if ! "$gh_bin" issue create --repo "$repo" --title "$title" \
      --label schema-canary-rollback --body-file "$bodyf" >/dev/null; then
    canary_log "canary: GitHub issue create failed — writing rollback fields to job summary"
    canary_rollback_summary "$bodyf"
    return 1
  fi
  canary_log "canary: opened GitHub issue label=schema-canary-rollback function=$fn old=$old new=$new"
  return 0
}

# Successful abort: pin FunctionVersion to old, clear weights, then open
# one GitHub issue. Always return 1 so Actions marks the tick failed.
abort_live_canary() {
  local fn="$1" region="$2" old="$3" new="$4" alarm="$5" revision="${6:-}"
  rollback_canary "$fn" "$region" "$old" "$revision" || return 1
  open_canary_rollback_issue "$alarm" "$fn" "$old" "$new" || true
  return 1
}

# Inspect the configured soak alarms.
# stdout: STATUS<TAB>FIRING
#   STATUS is ok | alarm | missing
#   FIRING is a comma-separated list of names in ALARM (empty unless STATUS=alarm)
# A missing/unreadable configured alarm is missing: the tick must not abort
# the alias. ALARM plus a valid canary aborts. ok means every name is
# OK or INSUFFICIENT_DATA.
canary_alarms_inspect() {
  local region="$1"
  local names name state status="ok" firing="" missing=0
  names="$(canary_default_alarm_names)"
  for name in $names; do
    state=$(aws cloudwatch describe-alarms --alarm-names "$name" --region "$region" \
      --query 'MetricAlarms[0].StateValue' --output text 2>/dev/null || echo "ERROR")
    canary_log "canary: alarm $name state=$state" >&2
    case "$state" in
      OK|INSUFFICIENT_DATA) ;;
      ALARM)
        if [ -n "$firing" ]; then
          firing="${firing},${name}"
        else
          firing="$name"
        fi
        status="alarm"
        ;;
      *)
        missing=1
        ;;
    esac
  done
  if [ "$missing" -eq 1 ]; then
    status="missing"
    firing=""
  fi
  printf '%s\t%s\n' "$status" "$firing"
}

# Check CloudWatch alarms for the schema function (any ALARM or missing → fail).
canary_alarms_ok() {
  local region="$1" out status
  out="$(canary_alarms_inspect "$region")"
  status="${out%%	*}"
  [ "$status" = "ok" ]
}

# Read the real alias shape. The clock is version-bound proof in Description;
# get-alias has no LastModified. Missing proof retains the pair for rollback.
# stdout: ACTION<TAB>old<TAB>new<TAB>revision<TAB>promote_after.
canary_alias_plan() {
  local fn="$1" region="$2" json
  json="$(aws lambda get-alias --function-name "$fn" --name live \
    --region "$region" --output json)" || return 1
  printf '%s\n' "$json" | python3 "$CANARY_ALIAS_HELPER" plan \
    --weight "$CANARY_WEIGHT" --soak-hours "$CANARY_SOAK_HOURS"
}

# GitHub ticker path. The live alias is the soak record: primary is the
# previous version, AdditionalVersionWeights at CANARY_WEIGHT is the new
# version, and Description stores the pair and the UTC start time.
# A runner-local canary-state.json does not survive the job.
#
# Abort order: describe both alarms first; a missing name fails before any
# alias mutation; empty weights exit 0; any other weight map fails; a
# deleted FunctionVersion fails; ALARM plus a valid canary rolls the alias
# back, opens one GitHub issue, and exits non-zero.
tick_alias_canaries() {
  local region fn plan action old new revision promote inspect status firing
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
  inspect="$(canary_alarms_inspect "$region")"
  IFS="$(printf '\t')" read -r status firing <<EOF
$inspect
EOF
  if [ "$status" = "missing" ]; then
    canary_log "ticker: missing configured alarm — no alias change"
    return 1
  fi
  if ! plan="$(canary_alias_plan "$fn" "$region")"; then
    canary_log "ticker: cannot read or validate the live alias — move no alias"
    return 1
  fi
  IFS="$(printf '\t')" read -r action old new revision promote <<EOF
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
    unproven|soaking|due) ;;
    *)
      canary_log "ticker: invalid canary plan — move no alias"
      return 1
      ;;
  esac
  if ! version_exists "$fn" "$region" "$old"; then
    canary_log "ticker: FunctionVersion $old deleted — move no alias"
    return 1
  fi
  if [ "$status" = "alarm" ]; then
    canary_log "ticker: ALARM ($firing) — rolling back $fn to $old (was canary $new)"
    abort_live_canary "$fn" "$region" "$old" "$new" "$firing" "$revision" || return 1
  fi
  if [ "$action" = "unproven" ]; then
    canary_log "ticker: missing or mismatched canary clock proof (primary=$old canary=$new) — no promotion; ALARM rollback remains active"
    return 1
  fi
  if [ "$action" = "due" ]; then
    promote_canary_full "$fn" "$region" "$new" "$revision" || return 1
    canary_log "ticker: PROMOTED $fn to 100% version=$new"
    return 0
  fi
  canary_log "ticker: $fn still soaking until $promote (primary=$old canary=$new)"
  return 0
}
