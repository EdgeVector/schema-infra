#!/usr/bin/env bash
# Promote schema-infra prod canary after soak if healthy.
# Safe to run every 15m via launchd. No-ops if no canary-state.json.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
# Refresh this checkout to canonical main before sourcing helpers, then
# re-exec so a previously stale launchd clone runs current ticker code.
# shellcheck source=scripts/deploy/canary-run-root.sh
source "$ROOT/scripts/deploy/canary-run-root.sh"
if [ "${CANARY_RUN_ROOT_REFRESHED:-}" != "1" ]; then
  before="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo none)"
  canary_refresh_run_root "$ROOT"
  export CANARY_RUN_ROOT_REFRESHED=1
  after="$(git -C "$ROOT" rev-parse HEAD)"
  if [ "$before" != "$after" ]; then
    exec /bin/bash "$ROOT/.lastgit/canary-ticker.sh"
  fi
fi
# shellcheck source=scripts/deploy/canary-lib.sh
source "$ROOT/scripts/deploy/canary-lib.sh"

# GitHub Actions has no durable local state file. The live alias is the record.
if [ "${CANARY_STATE_FROM_ALIAS:-}" = "1" ]; then
  tick_alias_canaries
  exit $?
fi

if [ ! -f "$STATE_FILE" ]; then
  exit 0
fi

if [ "${DEPLOY_FREEZE:-}" = "true" ]; then
  canary_log "ticker: DEPLOY_FREEZE — leave canary as-is"
  exit 0
fi

read_state() {
  python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); print(s.get(sys.argv[2],""))' "$STATE_FILE" "$1"
}

OID=$(read_state oid)
OLD=$(read_state old_version)
NEW=$(read_state new_version)
FN=$(read_state function_name)
REGION=$(read_state region)
PROMOTE_AFTER=$(read_state promote_after)
STAGE=$(read_state stage)
[ -n "$REGION" ] || REGION=us-east-1

if [ "$STAGE" != "canary_soak" ]; then
  canary_log "ticker: stage=$STAGE — nothing to do"
  exit 0
fi

inspect="$(canary_alarms_inspect "$REGION")"
IFS="$(printf '\t')" read -r alarm_status alarm_firing <<EOF
$inspect
EOF

if ! canary_soak_elapsed "$PROMOTE_AFTER"; then
  canary_log "ticker: still soaking until $PROMOTE_AFTER (oid=$OID)"
  if [ "$alarm_status" = "missing" ]; then
    canary_log "ticker: missing configured alarm — no alias change"
    exit 1
  fi
  if [ "$alarm_status" = "alarm" ]; then
    canary_log "ticker: ALARM during soak — rolling back"
    if [ -n "$OLD" ]; then
      abort_live_canary "$FN" "$REGION" "$OLD" "$NEW" "$alarm_firing" || true
    fi
    clear_canary_state
    exit 1
  fi
  exit 0
fi

canary_log "ticker: soak complete for oid=$OID — checking alarms"
if [ "$alarm_status" = "missing" ]; then
  canary_log "ticker: missing configured alarm — no alias change"
  exit 1
fi
if [ "$alarm_status" = "alarm" ]; then
  canary_log "ticker: ALARM at promote time — rolling back"
  if [ -n "$OLD" ]; then
    abort_live_canary "$FN" "$REGION" "$OLD" "$NEW" "$alarm_firing" || true
  fi
  clear_canary_state
  exit 1
fi

promote_canary_full "$FN" "$REGION" "$NEW"
clear_canary_state
canary_log "ticker: PROMOTED oid=$OID to 100% version=$NEW"
echo "schema canary promoted oid=$OID version=$NEW"
