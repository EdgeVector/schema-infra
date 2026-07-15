#!/usr/bin/env bash
# Dev smoke tests for schema-infra after deploy.
# Exit 0 only if critical surfaces respond as expected on the NEW stack.
set -euo pipefail

REGION="${AWS_REGION:-us-west-2}"
STACK="SchemaServiceStack-dev"

API_URL=$(aws cloudformation describe-stacks \
  --stack-name "$STACK" \
  --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`SchemaServiceApiUrl`].OutputValue' \
  --output text)

if [ -z "$API_URL" ] || [ "$API_URL" = "None" ]; then
  echo "FAIL: no SchemaServiceApiUrl for $STACK" >&2
  exit 1
fi

echo "== schema smoke-dev against $API_URL =="

fail=0
check() {
  local path="$1" expect_code="$2" expect_substr="${3:-}"
  local code body
  body=$(curl -sS -m 45 -w "\n%{http_code}" "${API_URL}${path}" || echo -e "\n000")
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

# Healthy core surfaces
check "/v1/health" "200" "healthy"
check "/health" "200" "healthy"
check "/v1/schemas" "200" "schemas"

# Dead planes must NOT be served by Lambda as success (APIGW or Lambda 404 both OK)
# After canary CDK: APIGW 404 for unmounted routes. Before: Lambda may return JSON 404.
for path in /v1/views /v1/transforms /api/schemas; do
  code=$(curl -sS -m 20 -o /dev/null -w "%{http_code}" "${API_URL}${path}" || echo 000)
  case "$code" in
    404|403) echo "OK   $path HTTP $code (dead surface)" ;;
    *) echo "FAIL $path: HTTP $code (dead surface should 404)"; fail=1 ;;
  esac
done

# Shared-only must be mounted (auth may 401/403 without key — not APIGW 404)
code=$(curl -sS -m 20 -o /tmp/schema-shared-only.out -w "%{http_code}" \
  "${API_URL}/v1/snapshot/shared-only" || echo 000)
case "$code" in
  200|401|403) echo "OK   /v1/snapshot/shared-only HTTP $code (mounted)" ;;
  404)
    # Allow brief lag if stage not updated yet; still fail hard for smoke
    echo "FAIL /v1/snapshot/shared-only HTTP 404 (route missing on gateway)"
    fail=1
    ;;
  *) echo "FAIL /v1/snapshot/shared-only HTTP $code"; fail=1 ;;
esac

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
  echo "schema smoke-dev FAILED"
  exit 1
fi
echo "schema smoke-dev PASSED"
