#!/usr/bin/env bash
#
# Post-deploy smoke test for the Transform Worker Split flow.
#
# Runs end-to-end against a deployed schema service stack:
#   1. POST /v1/transforms with a minimal Rust source.
#   2. Accept 202 (async enqueue) or 200/201 (sync / cache hit).
#   3. If 202, poll GET /v1/transform-jobs/{id} with exponential
#      backoff until the worker commits a terminal status. Succeeded
#      is pass; anything else is fail.
#   4. Validate the final TransformRecord shape: presence of hash,
#      name, max_gas, and one output field.
#
# Intended to be called from `.github/workflows/deploy.yml` right after
# the dev CDK deploy succeeds and before the prod deploy runs.
#
# Usage:
#     API_URL=https://schema-dev... ./test/e2e/transform-async-flow.sh
#     API_URL=... TIMEOUT_SECS=180 ./test/e2e/transform-async-flow.sh
#
# Exit codes:
#   0 — smoke passed (transform registered, final shape valid)
#   1 — submission rejected (4xx on initial POST)
#   2 — polling timed out (worker never committed a terminal status)
#   3 — worker committed a terminal failure
#   4 — final record missing required fields
#   5 — environment misconfigured (API_URL missing, curl/jq unavailable)
#
# `projects/transform-worker-split` Lane E post-deploy smoke — see
# `gbrain get projects/transform-worker-split` for the plan.

set -euo pipefail

require_env() {
  local name="$1"
  if [ -z "${!name:-}" ]; then
    echo "FAIL: \$$name is not set" >&2
    exit 5
  fi
}

require_cmd() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "FAIL: required command '$name' not found on PATH" >&2
    exit 5
  fi
}

require_env API_URL
require_cmd curl
require_cmd jq

API_URL="${API_URL%/}"
TIMEOUT_SECS="${TIMEOUT_SECS:-180}"
# The Rust source is committed here inline so the smoke is self-contained.
# Any tweak changes `sha256(rust_source)`, which in turn changes the
# job_id and the deduped wasm_hash. Keep it minimal — identity fn only.
RUST_SOURCE='fn transform_impl(input: serde_json::Value) -> serde_json::Value {
    serde_json::json!({ "out": input.get("out").cloned().unwrap_or(serde_json::json!("ok")) })
}'
REQUEST_JSON=$(jq -n \
  --arg src "$RUST_SOURCE" \
  '{
    name: "post_deploy_smoke_transform",
    version: "1.0.0",
    description: "Transform Worker Split post-deploy smoke",
    input_queries: [],
    output_fields: { out: "String" },
    rust_source: $src,
    max_gas: 1000000000
  }')

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

log "Submitting POST $API_URL/v1/transforms"
TMPHEADERS=$(mktemp)
TMPBODY=$(mktemp)
trap 'rm -f "$TMPHEADERS" "$TMPBODY"' EXIT

HTTP_CODE=$(curl -sS -w "%{http_code}" \
  -o "$TMPBODY" -D "$TMPHEADERS" \
  -H 'Content-Type: application/json' \
  --max-time 30 \
  -X POST "$API_URL/v1/transforms" \
  -d "$REQUEST_JSON")

BODY=$(cat "$TMPBODY")
log "HTTP $HTTP_CODE"

case "$HTTP_CODE" in
  200|201)
    # Sync path or async cache hit — record is already in the body.
    # Validate shape below against the terminal TransformRecord.
    RECORD=$(echo "$BODY" | jq -c '.record // empty')
    if [ -z "$RECORD" ] || [ "$RECORD" = "null" ]; then
      echo "FAIL: 2xx response missing .record field. Body: $BODY" >&2
      exit 4
    fi
    log "Sync path / cache hit — received record inline"
    ;;
  202)
    JOB_ID=$(echo "$BODY" | jq -r '.job_id // empty')
    if [ -z "$JOB_ID" ]; then
      echo "FAIL: 202 response missing .job_id. Body: $BODY" >&2
      exit 4
    fi
    log "Enqueued job_id=$JOB_ID — entering poll loop"

    DEADLINE=$(($(date +%s) + TIMEOUT_SECS))
    # Mirror the SDK's poll cadence: 500ms → 5s cap (but in whole
    # seconds for sleep compatibility inside a shell loop).
    DELAY=1
    while :; do
      NOW=$(date +%s)
      if [ "$NOW" -ge "$DEADLINE" ]; then
        echo "FAIL: transform job $JOB_ID still pending after ${TIMEOUT_SECS}s timeout" >&2
        echo "last body: $BODY" >&2
        exit 2
      fi

      HTTP_CODE=$(curl -sS -w "%{http_code}" \
        -o "$TMPBODY" --max-time 30 \
        "$API_URL/v1/transform-jobs/$JOB_ID")
      BODY=$(cat "$TMPBODY")

      if [ "$HTTP_CODE" != "200" ]; then
        echo "FAIL: job-status GET returned HTTP $HTTP_CODE: $BODY" >&2
        exit 3
      fi

      STATUS=$(echo "$BODY" | jq -r '.status // empty')
      case "$STATUS" in
        Succeeded)
          RECORD=$(echo "$BODY" | jq -c '.record // empty')
          if [ -z "$RECORD" ] || [ "$RECORD" = "null" ]; then
            echo "FAIL: Succeeded status missing .record. Body: $BODY" >&2
            exit 4
          fi
          log "Worker committed Succeeded status"
          break
          ;;
        pending)
          log "status=pending — sleeping ${DELAY}s"
          sleep "$DELAY"
          DELAY=$(( DELAY * 2 ))
          if [ "$DELAY" -gt 5 ]; then DELAY=5; fi
          continue
          ;;
        CompileFailed|CompileTimeout|InvalidOutputShape|TransformPanicked)
          MSG=$(echo "$BODY" | jq -r '.error_message // "<no error_message>"')
          echo "FAIL: worker terminated job with $STATUS" >&2
          echo "error_message: $MSG" >&2
          exit 3
          ;;
        *)
          echo "FAIL: unexpected job status '$STATUS'. Body: $BODY" >&2
          exit 3
          ;;
      esac
    done
    ;;
  *)
    echo "FAIL: POST /v1/transforms returned HTTP $HTTP_CODE" >&2
    echo "body: $BODY" >&2
    exit 1
    ;;
esac

# Validate final record shape. Only check fields the SDK / UI rely on;
# metadata like classification / NMI matrix is worker-determined and
# not part of the smoke contract.
HASH=$(echo "$RECORD" | jq -r '.hash // empty')
NAME=$(echo "$RECORD" | jq -r '.name // empty')
MAX_GAS=$(echo "$RECORD" | jq -r '.max_gas // empty')
OUT_FIELD=$(echo "$RECORD" | jq -r '.output_schema.out // empty')

for pair in "HASH=$HASH" "NAME=$NAME" "MAX_GAS=$MAX_GAS" "OUT_FIELD=$OUT_FIELD"; do
  key="${pair%%=*}"
  value="${pair#*=}"
  if [ -z "$value" ]; then
    echo "FAIL: record missing $key. Record: $RECORD" >&2
    exit 4
  fi
done

if [ "$NAME" != "post_deploy_smoke_transform" ]; then
  echo "FAIL: record.name='$NAME', expected post_deploy_smoke_transform" >&2
  exit 4
fi
if [ "$OUT_FIELD" != "String" ]; then
  echo "FAIL: record.output_schema.out='$OUT_FIELD', expected 'String'" >&2
  exit 4
fi

log "PASS — transform registered"
log "  hash:    $HASH"
log "  max_gas: $MAX_GAS"
exit 0
