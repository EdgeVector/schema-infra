#!/usr/bin/env bash
# Prove the deployed Schema Service mutation PoW path with the real Rust client.
# Output is one secret-safe JSON object; diagnostics go to stderr.
set -euo pipefail

ENVIRONMENT="dev"
ALLOW_PROD=0
QUOTA_PROBE=0
MAX_QUOTA_ATTEMPTS=65

usage() {
  echo "usage: $0 [--environment dev|prod] [--allow-prod] [--quota-probe] [--max-quota-attempts N]" >&2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --environment) ENVIRONMENT="${2:-}"; shift 2 ;;
    --allow-prod) ALLOW_PROD=1; shift ;;
    --quota-probe) QUOTA_PROBE=1; shift ;;
    --max-quota-attempts) MAX_QUOTA_ATTEMPTS="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; echo "FAIL: unknown argument: $1" >&2; exit 2 ;;
  esac
done

case "$ENVIRONMENT" in
  dev) REGION="${AWS_REGION:-us-west-2}" ;;
  prod)
    REGION="${AWS_REGION:-us-east-1}"
    [ "$ALLOW_PROD" -eq 1 ] || { echo "FAIL: production proof requires --allow-prod" >&2; exit 2; }
    [ "$QUOTA_PROBE" -eq 0 ] || { echo "FAIL: quota probe is dev-only" >&2; exit 2; }
    ;;
  *) echo "FAIL: environment must be dev or prod" >&2; exit 2 ;;
esac
case "$MAX_QUOTA_ATTEMPTS" in
  ''|*[!0-9]*) echo "FAIL: --max-quota-attempts must be an integer" >&2; exit 2 ;;
esac
[ "$MAX_QUOTA_ATTEMPTS" -ge 1 ] && [ "$MAX_QUOTA_ATTEMPTS" -le 130 ] || {
  echo "FAIL: --max-quota-attempts must be between 1 and 130" >&2
  exit 2
}

for command_name in aws cargo jq; do
  command -v "$command_name" >/dev/null || { echo "FAIL: missing $command_name" >&2; exit 1; }
done

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
STACK="SchemaServiceStack-$ENVIRONMENT"
stack_output() {
  aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey==\`$1\`].OutputValue" --output text
}

API_URL=$(stack_output SchemaServiceApiUrl)
FUNCTION_NAME=$(stack_output SchemaServiceFunctionName)
QUOTA_TABLE=$(stack_output MutationGateQuotaTableName)
for value in "$API_URL" "$FUNCTION_NAME" "$QUOTA_TABLE"; do
  [ -n "$value" ] && [ "$value" != "None" ] || { echo "FAIL: required stack output missing" >&2; exit 1; }
done

ENFORCE=$(aws lambda get-function-configuration --function-name "$FUNCTION_NAME" --region "$REGION" \
  --query 'Environment.Variables.SCHEMA_MUTATION_GATE_ENFORCE' --output text)
[ "$ENFORCE" = "true" ] || { echo "FAIL: mutation gate enforcement is not true in $ENVIRONMENT" >&2; exit 1; }

ddb_count() {
  aws dynamodb scan --table-name "$QUOTA_TABLE" --region "$REGION" --select COUNT \
    --query Count --output text
}

log_count() {
  local start_ms="$1" pattern="$2"
  aws logs filter-log-events --region "$REGION" --log-group-name "/aws/lambda/$FUNCTION_NAME" \
    --start-time "$start_ms" --filter-pattern "$pattern" --output json |
    jq -r '.events | length'
}

wait_for_log() {
  local start_ms="$1" pattern="$2" attempts=0 count=0
  while [ "$attempts" -lt 18 ]; do
    count=$(log_count "$start_ms" "$pattern")
    if [ "${count:-0}" -gt 0 ]; then
      echo "$count"
      return 0
    fi
    attempts=$((attempts + 1))
    sleep 5
  done
  echo 0
  return 1
}

wait_for_initial_rejection() {
  local start_ms="$1" attempts=0 node_key_count=0 pow_count=0 count=0
  while [ "$attempts" -lt 18 ]; do
    node_key_count=$(log_count "$start_ms" '"schema_mutation_gate_enforce_total" "node_key_required"')
    pow_count=$(log_count "$start_ms" '"schema_mutation_gate_enforce_total" "proof_of_work_required"')
    count=$((node_key_count + pow_count))
    if [ "$count" -gt 0 ]; then
      echo "$count"
      return 0
    fi
    attempts=$((attempts + 1))
    sleep 5
  done
  echo 0
  return 1
}

START_EPOCH=$(date +%s)
START_MS="${START_EPOCH}000"
BEFORE_DDB=$(ddb_count)
RUN_ID="proof-${START_EPOCH}"

echo "running real client proof against $ENVIRONMENT" >&2
PROBE_ARGS=(--url "$API_URL" --environment "$ENVIRONMENT")
if [ "$ENVIRONMENT" = prod ]; then
  PROBE_ARGS+=(--allow-prod)
else
  PROBE_ARGS+=(--run-id "$RUN_ID")
fi
CLIENT_REPORT=$(cargo run --quiet --manifest-path "$ROOT/fold/Cargo.toml" \
  -p schema_service_client --example schema_pow_live_probe -- "${PROBE_ARGS[@]}")
echo "$CLIENT_REPORT" | jq -e '.status == "PASS" and .private_key_persisted == false' >/dev/null

CHALLENGES=$(wait_for_log "$START_MS" '"schema_mutation_gate_challenge_total" "issued"') || {
  echo "FAIL: challenge telemetry did not arrive" >&2; exit 1;
}
ACCEPTED=$(wait_for_log "$START_MS" '"schema_mutation_gate_enforce_total" "status" "ok"') || {
  echo "FAIL: enforcement telemetry did not arrive" >&2; exit 1;
}
INITIAL_REJECTION=$(wait_for_initial_rejection "$START_MS") || {
  echo "FAIL: initial mutation-gate rejection telemetry did not arrive" >&2; exit 1;
}
AFTER_DDB=$(ddb_count)
[ "$AFTER_DDB" -gt "$BEFORE_DDB" ] || {
  echo "FAIL: DynamoDB quota state did not grow ($BEFORE_DDB -> $AFTER_DDB)" >&2
  exit 1
}

QUOTA_ATTEMPTS=0
QUOTA_REJECTS=0
if [ "$QUOTA_PROBE" -eq 1 ]; then
  QUOTA_START_MS="$(date +%s)000"
  while [ "$QUOTA_ATTEMPTS" -lt "$MAX_QUOTA_ATTEMPTS" ]; do
    QUOTA_ATTEMPTS=$((QUOTA_ATTEMPTS + 1))
    if ! cargo run --quiet --manifest-path "$ROOT/fold/Cargo.toml" \
      -p schema_service_client --example schema_pow_live_probe -- \
      --url "$API_URL" --environment dev \
      --run-id "quota-${START_EPOCH}-${QUOTA_ATTEMPTS}" >/dev/null; then
      QUOTA_REJECTS=$(wait_for_log "$QUOTA_START_MS" '"schema_mutation_gate_enforce_total" "quota_exceeded"' || true)
      [ "$QUOTA_REJECTS" -gt 0 ] || {
        echo "FAIL: client failed before a quota_exceeded signal appeared" >&2
        exit 1
      }
      break
    fi
  done
  [ "$QUOTA_REJECTS" -gt 0 ] || {
    echo "FAIL: no quota rejection within $MAX_QUOTA_ATTEMPTS attempts" >&2
    exit 1
  }
fi

jq -cn \
  --arg environment "$ENVIRONMENT" \
  --argjson client "$CLIENT_REPORT" \
  --argjson challenge_events "$CHALLENGES" \
  --argjson accepted_events "$ACCEPTED" \
  --argjson initial_rejection_events "$INITIAL_REJECTION" \
  --argjson quota_items_before "$BEFORE_DDB" \
  --argjson quota_items_after "$AFTER_DDB" \
  --argjson quota_probe "$QUOTA_PROBE" \
  --argjson quota_attempts "$QUOTA_ATTEMPTS" \
  --argjson quota_reject_events "$QUOTA_REJECTS" \
  '{status:"PASS", environment:$environment, client:$client,
    telemetry:{challenge_events:$challenge_events,accepted_events:$accepted_events,
      initial_rejection_events:$initial_rejection_events,quota_reject_events:$quota_reject_events},
    quota_state:{items_before:$quota_items_before,items_after:$quota_items_after},
    quota_probe:{enabled:($quota_probe == 1),attempts:$quota_attempts}}'
