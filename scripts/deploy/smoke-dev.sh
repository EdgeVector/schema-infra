#!/usr/bin/env bash
# Smoke checks for schema-infra after deploy.
# Exit 0 only if critical advisory surfaces respond as expected on the stack.
set -euo pipefail

ENVIRONMENT="${1:-${SCHEMA_SMOKE_ENV:-dev}}"
case "$ENVIRONMENT" in
  prod) DEFAULT_REGION="us-east-1" ;;
  dev) DEFAULT_REGION="us-west-2" ;;
  *) echo "FAIL: unknown smoke environment: $ENVIRONMENT" >&2; exit 1 ;;
esac

REGION="${AWS_REGION:-$DEFAULT_REGION}"
STACK="SchemaServiceStack-$ENVIRONMENT"

# Per-run evidence directory per AGENTS.md generated-evidence rule
if [ -n "${RUNNER_TEMP:-}" ]; then
  EVIDENCE_DIR="$RUNNER_TEMP"
elif [ -n "${LAST_STACK_EVIDENCE_ROOT:-}" ]; then
  EVIDENCE_DIR="$LAST_STACK_EVIDENCE_ROOT"
else
  EVIDENCE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/last-stack/artifacts/schema-infra/$(date +%Y%m%d-%H%M%S)-$$"
  mkdir -p "$EVIDENCE_DIR"
fi

API_URL=$(aws cloudformation describe-stacks \
  --stack-name "$STACK" \
  --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`SchemaServiceApiUrl`].OutputValue' \
  --output text)

if [ -z "$API_URL" ] || [ "$API_URL" = "None" ]; then
  echo "FAIL: no SchemaServiceApiUrl for $STACK" >&2
  exit 1
fi

echo "== schema smoke-$ENVIRONMENT against $API_URL =="

fail=0
check() {
  local path="$1" expect_code="$2" expect_substr="$3"
  shift 3
  local code body
  body=$(curl -sS -m 45 -w "\n%{http_code}" "$@" "${API_URL}${path}" || echo -e "\n000")
  code=$(echo "$body" | tail -1)
  body=$(echo "$body" | sed '$d')
  if [ "$code" != "$expect_code" ]; then
    echo "FAIL $path: HTTP $code (want $expect_code) body=$(echo "$body" | cut -c1-120)"
    fail=1
    return
  fi
  if [ -n "$expect_substr" ] && ! echo "$body" | grep -q "$expect_substr"; then
    echo "FAIL $path: missing '$expect_substr' in body=$(echo "$body" | cut -c1-120)"
    fail=1
    return
  fi
  echo "OK   $path HTTP $code"
}

# Healthy advisory surfaces
check "/v1/health" "200" "healthy"
check "/health" "200" "healthy"
check "/v1/fields/vocabulary" "200" "fields"
check "/v1/advice/schema" "200" "findings" \
  -X POST -H 'Content-Type: application/json' \
  -d '{"schema":{"name":"Note","fields":["note_title"],"field_types":{"note_title":"String"}}}'

# Dead planes must NOT be served by Lambda as success (APIGW or Lambda 404 both OK)
for path in /v1/views /v1/transforms /api/schemas; do
  code=$(curl -sS -m 20 -o /dev/null -w "%{http_code}" "${API_URL}${path}" || echo 000)
  case "$code" in
    404|403) echo "OK   $path HTTP $code (dead surface)" ;;
    *) echo "FAIL $path: HTTP $code (dead surface should 404)"; fail=1 ;;
  esac
done

if [ "$ENVIRONMENT" = "prod" ]; then
  DOMAIN=$(aws cloudformation describe-stacks \
    --stack-name "$STACK" \
    --region "$REGION" \
    --query 'Stacks[0].Outputs[?OutputKey==`SchemaServiceDomain`].OutputValue' \
    --output text 2>/dev/null || true)
  DOMAIN_TARGET=$(aws cloudformation describe-stacks \
    --stack-name "$STACK" \
    --region "$REGION" \
    --query 'Stacks[0].Outputs[?OutputKey==`SchemaServiceDomainTarget`].OutputValue' \
    --output text 2>/dev/null || true)

  if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "None" ] && \
     [ -n "$DOMAIN_TARGET" ] && [ "$DOMAIN_TARGET" != "None" ]; then
    code=$(curl -sS -m 20 \
      --connect-to "${DOMAIN}:443:${DOMAIN_TARGET}:443" \
      -o "$EVIDENCE_DIR/schema-vocabulary-domain.out" \
      -w "%{http_code}" \
      "https://${DOMAIN}/v1/fields/vocabulary" || echo 000)
    body=$(cat "$EVIDENCE_DIR/schema-vocabulary-domain.out" 2>/dev/null || true)
    case "$code" in
      200)
        if echo "$body" | grep -q "fields"; then
          echo "OK   ${DOMAIN}/v1/fields/vocabulary HTTP 200 (mounted)"
        else
          echo "FAIL ${DOMAIN}/v1/fields/vocabulary missing 'fields' in body"
          fail=1
        fi
        ;;
      404)
        echo "FAIL ${DOMAIN}/v1/fields/vocabulary HTTP 404 (custom-domain route missing)"
        fail=1
        ;;
      *) echo "FAIL ${DOMAIN}/v1/fields/vocabulary HTTP $code"; fail=1 ;;
    esac
  else
    echo "FAIL: missing prod custom-domain outputs for $STACK"
    fail=1
  fi
fi

# Anthropic env must be gone on the live function
FN=$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`SchemaServiceFunctionName`].OutputValue' --output text)
if [ -n "$FN" ] && [ "$FN" != "None" ]; then
  has=$(aws lambda get-function-configuration --function-name "$FN" --region "$REGION" \
    --query 'Environment.Variables.ANTHROPIC_API_KEY_SECRET_ARN' --output text 2>/dev/null || echo "None")
  if [ "$has" = "None" ] || [ -z "$has" ] || [ "$has" = "null" ]; then
    echo "OK   no ANTHROPIC_API_KEY_SECRET_ARN on function env"
  else
    echo "FAIL ANTHROPIC_API_KEY_SECRET_ARN still set on Lambda env"
    fail=1
  fi
fi

if [ "$fail" -ne 0 ]; then
  echo "schema smoke-$ENVIRONMENT FAILED"
  exit 1
fi
echo "schema smoke-$ENVIRONMENT PASSED"
