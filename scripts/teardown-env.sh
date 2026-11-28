#!/usr/bin/env bash
# Tear down SchemaServiceStack-<env> and wipe retained data.
#
# Tom, 2026-11-27: retire the LastDB schema service. Ops go through CI only.
# Sequence:
#   1. Discover live resources from the stack (if present) and naming conventions.
#   2. Empty the private catalog S3 bucket (all versions + delete markers).
#   3. Delete the embeddings DynamoDB table.
#   4. cdk destroy the service stack (teardown context; no fold asset needed).
#   5. Force-delete any leftovers (bucket, table, log groups, alarms, domain).
#   6. Verify each resource is gone (describe → not-found) and print evidence.
#
# Usage: scripts/teardown-env.sh <dev|prod>
# Env:   AWS credentials already assumed (OIDC role). CDK_DEFAULT_ACCOUNT set.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_NAME="${1:?usage: teardown-env.sh <dev|prod>}"
case "$ENV_NAME" in
  dev) REGION="us-west-2" ;;
  prod) REGION="us-east-1" ;;
  *) echo "ENV must be dev or prod" >&2; exit 1 ;;
esac

ACCOUNT="${CDK_DEFAULT_ACCOUNT:-${AWS_ACCOUNT_ID:-152335099025}}"
export AWS_REGION="$REGION"
export AWS_DEFAULT_REGION="$REGION"
export CDK_DEFAULT_ACCOUNT="$ACCOUNT"
export CDK_DEFAULT_REGION="$REGION"

STACK="SchemaServiceStack-${ENV_NAME}"
BUCKET="schema-service-${ENV_NAME}-${ACCOUNT}"
TABLE="schema-embeddings-${ENV_NAME}-canonical-v2"
ALARM_LAMBDA="schema-service-lambda-errors-${ENV_NAME}"
ALARM_HTTP="schema-service-http-5xx-${ENV_NAME}"
API_NAME="schema-service-${ENV_NAME}"
DOMAIN_NAME="schema.folddb.com"
FN_PREFIX="SchemaServiceStack-${ENV_NAME}-"

echo "=== Schema service teardown: env=${ENV_NAME} region=${REGION} account=${ACCOUNT} ==="

evidence() {
  printf 'EVIDENCE[%s] %s\n' "$ENV_NAME" "$*"
}

stack_status() {
  aws cloudformation describe-stacks --stack-name "$STACK" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "NOT_FOUND"
}

empty_versioned_bucket() {
  local bucket="$1"
  if ! aws s3api head-bucket --bucket "$bucket" 2>/dev/null; then
    evidence "s3://${bucket}: already absent before empty"
    return 0
  fi
  evidence "s3://${bucket}: emptying all object versions and delete markers (schema-catalog-v2/ + advisory-catalog-v1/ + any other keys)"
  python3 - "$bucket" <<'PY'
import json, subprocess, sys, tempfile, os

bucket = sys.argv[1]
key_marker = None
version_marker = None
total = 0
while True:
    cmd = ["aws", "s3api", "list-object-versions", "--bucket", bucket, "--output", "json"]
    if key_marker:
        cmd.extend(["--key-marker", key_marker])
    if version_marker:
        cmd.extend(["--version-id-marker", version_marker])
    page = json.loads(subprocess.check_output(cmd))
    objs = []
    for key in ("Versions", "DeleteMarkers"):
        for o in page.get(key) or []:
            objs.append({"Key": o["Key"], "VersionId": o["VersionId"]})
    for i in range(0, len(objs), 1000):
        batch = objs[i : i + 1000]
        payload = {"Objects": batch, "Quiet": True}
        with tempfile.NamedTemporaryFile("w", delete=False) as f:
            json.dump(payload, f)
            name = f.name
        try:
            subprocess.check_call(
                ["aws", "s3api", "delete-objects", "--bucket", bucket, "--delete", f"file://{name}"]
            )
        finally:
            os.unlink(name)
        total += len(batch)
    if page.get("IsTruncated"):
        key_marker = page.get("NextKeyMarker") or None
        version_marker = page.get("NextVersionIdMarker") or None
    else:
        break
print(f"deleted_entries={total}", flush=True)
PY
  evidence "s3://${bucket}: empty complete"
}

delete_bucket() {
  local bucket="$1"
  if ! aws s3api head-bucket --bucket "$bucket" 2>/dev/null; then
    evidence "s3://${bucket}: not-found (delete skipped)"
    return 0
  fi
  empty_versioned_bucket "$bucket"
  aws s3api delete-bucket --bucket "$bucket"
  evidence "s3://${bucket}: deleted"
}

delete_table() {
  local table="$1"
  if ! aws dynamodb describe-table --table-name "$table" >/dev/null 2>&1; then
    evidence "dynamodb ${table}: already absent"
    return 0
  fi
  evidence "dynamodb ${table}: deleting"
  aws dynamodb delete-table --table-name "$table" >/dev/null
  aws dynamodb wait table-not-exists --table-name "$table" || true
  evidence "dynamodb ${table}: deleted"
}

# --- discover ----------------------------------------------------------------

STATUS="$(stack_status)"
evidence "cloudformation ${STACK}: status=${STATUS}"

FN_NAMES=()
if [ "$STATUS" != "NOT_FOUND" ]; then
  mapfile -t FN_NAMES < <(aws cloudformation describe-stack-resources \
    --stack-name "$STACK" \
    --query "StackResources[?ResourceType=='AWS::Lambda::Function'].PhysicalResourceId" \
    --output text 2>/dev/null | tr '\t' '\n' | sed '/^$/d' || true)
fi
if [ "${#FN_NAMES[@]}" -eq 0 ]; then
  mapfile -t FN_NAMES < <(aws lambda list-functions \
    --query "Functions[?starts_with(FunctionName, '${FN_PREFIX}')].FunctionName" \
    --output text 2>/dev/null | tr '\t' '\n' | sed '/^$/d' || true)
fi
evidence "lambda functions: ${FN_NAMES[*]:-<none>}"

API_ID="$(aws apigatewayv2 get-apis \
  --query "Items[?Name=='${API_NAME}'].ApiId | [0]" --output text 2>/dev/null || echo None)"
[ "$API_ID" = "None" ] && API_ID=""
evidence "http api ${API_NAME}: ${API_ID:-<none>}"

# --- wipe data (override live RETAIN DeletionPolicy) -------------------------
# CloudFormation destroy honors the *live* template DeletionPolicy. Historical
# templates used RETAIN for the catalog bucket and embeddings table, so we
# empty/delete them explicitly via CLI before/after cdk destroy. We do NOT
# `cdk deploy` a DESTROY-policy update first: that would recreate wiped data.

empty_versioned_bucket "$BUCKET"
delete_table "$TABLE"

# --- cdk destroy -------------------------------------------------------------

cd "$ROOT/cdk"
if [ ! -d node_modules ]; then
  npm ci
fi
npm run build

if [ "$STATUS" != "NOT_FOUND" ]; then
  evidence "cdk destroy ${STACK} starting (context teardown=true for stub synth only)"
  # teardown=true selects the committed stub asset and skips the prod live pin
  # so destroy can synth without fold/server_lambda (removed upstream).
  npx cdk destroy "$STACK" \
    --context "environment=${ENV_NAME}" \
    --context teardown=true \
    --force
  evidence "cdk destroy ${STACK}: finished"
else
  evidence "cdk destroy skipped: stack already absent"
fi

# --- leftovers ---------------------------------------------------------------

delete_bucket "$BUCKET"
delete_table "$TABLE"

for alarm in "$ALARM_LAMBDA" "$ALARM_HTTP"; do
  if aws cloudwatch describe-alarms --alarm-names "$alarm" \
      --query 'MetricAlarms[0].AlarmName' --output text 2>/dev/null \
      | grep -qx "$alarm"; then
    aws cloudwatch delete-alarms --alarm-names "$alarm"
    evidence "alarm ${alarm}: deleted"
  else
    evidence "alarm ${alarm}: already absent"
  fi
done

mapfile -t LOG_GROUPS < <(aws logs describe-log-groups \
  --log-group-name-prefix "/aws/lambda/${FN_PREFIX}" \
  --query 'logGroups[].logGroupName' --output text 2>/dev/null \
  | tr '\t' '\n' | sed '/^$/d' || true)
if [ "${#LOG_GROUPS[@]}" -eq 0 ]; then
  evidence "log-groups /aws/lambda/${FN_PREFIX}*: already absent"
else
  for lg in "${LOG_GROUPS[@]}"; do
    [ -n "$lg" ] || continue
    aws logs delete-log-group --log-group-name "$lg"
    evidence "log-group ${lg}: deleted"
  done
fi

for fn in "${FN_NAMES[@]:-}"; do
  [ -n "$fn" ] || continue
  if aws lambda get-function --function-name "$fn" >/dev/null 2>&1; then
    aws lambda delete-function --function-name "$fn" || true
    evidence "lambda ${fn}: deleted leftover"
  fi
done

if [ "$ENV_NAME" = "prod" ]; then
  if aws apigatewayv2 get-domain-name --domain-name "$DOMAIN_NAME" >/dev/null 2>&1; then
    mapfile -t MAP_IDS < <(aws apigatewayv2 get-api-mappings \
      --domain-name "$DOMAIN_NAME" \
      --query 'Items[].ApiMappingId' --output text 2>/dev/null \
      | tr '\t' '\n' | sed '/^$/d' || true)
    for mid in "${MAP_IDS[@]:-}"; do
      [ -n "$mid" ] || continue
      aws apigatewayv2 delete-api-mapping --domain-name "$DOMAIN_NAME" --api-mapping-id "$mid" || true
      evidence "api-mapping ${mid} on ${DOMAIN_NAME}: deleted"
    done
    aws apigatewayv2 delete-domain-name --domain-name "$DOMAIN_NAME" || true
    evidence "apigw domain ${DOMAIN_NAME}: deleted"
  else
    evidence "apigw domain ${DOMAIN_NAME}: already absent"
  fi
fi

# --- verify ------------------------------------------------------------------

FAIL=0

if [ "$(stack_status)" != "NOT_FOUND" ]; then
  evidence "VERIFY FAIL: cloudformation ${STACK} still exists ($(stack_status))"
  FAIL=1
else
  evidence "VERIFY OK: cloudformation ${STACK} not-found"
fi

if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  evidence "VERIFY FAIL: s3://${BUCKET} still exists"
  FAIL=1
else
  evidence "VERIFY OK: s3://${BUCKET} not-found"
fi

if aws dynamodb describe-table --table-name "$TABLE" >/dev/null 2>&1; then
  evidence "VERIFY FAIL: dynamodb ${TABLE} still exists"
  FAIL=1
else
  evidence "VERIFY OK: dynamodb ${TABLE} not-found"
fi

for alarm in "$ALARM_LAMBDA" "$ALARM_HTTP"; do
  present="$(aws cloudwatch describe-alarms --alarm-names "$alarm" \
    --query 'length(MetricAlarms)' --output text 2>/dev/null || echo 0)"
  if [ "${present:-0}" != "0" ]; then
    evidence "VERIFY FAIL: alarm ${alarm} still exists"
    FAIL=1
  else
    evidence "VERIFY OK: alarm ${alarm} not-found"
  fi
done

api_left="$(aws apigatewayv2 get-apis \
  --query "Items[?Name=='${API_NAME}'].ApiId | [0]" --output text 2>/dev/null || echo None)"
if [ -n "$api_left" ] && [ "$api_left" != "None" ]; then
  evidence "VERIFY FAIL: http api ${API_NAME} still exists (${api_left})"
  FAIL=1
else
  evidence "VERIFY OK: http api ${API_NAME} not-found"
fi

fn_left="$(aws lambda list-functions \
  --query "Functions[?starts_with(FunctionName, '${FN_PREFIX}')].FunctionName | [0]" \
  --output text 2>/dev/null || echo None)"
if [ -n "$fn_left" ] && [ "$fn_left" != "None" ]; then
  evidence "VERIFY FAIL: lambda prefix ${FN_PREFIX} still has ${fn_left}"
  FAIL=1
else
  evidence "VERIFY OK: lambda prefix ${FN_PREFIX}* not-found"
fi

lg_left="$(aws logs describe-log-groups \
  --log-group-name-prefix "/aws/lambda/${FN_PREFIX}" \
  --query 'logGroups[0].logGroupName' --output text 2>/dev/null || echo None)"
if [ -n "$lg_left" ] && [ "$lg_left" != "None" ]; then
  evidence "VERIFY FAIL: log group still exists (${lg_left})"
  FAIL=1
else
  evidence "VERIFY OK: log-groups /aws/lambda/${FN_PREFIX}* not-found"
fi

if [ "$ENV_NAME" = "prod" ]; then
  if aws apigatewayv2 get-domain-name --domain-name "$DOMAIN_NAME" >/dev/null 2>&1; then
    evidence "VERIFY FAIL: apigw domain ${DOMAIN_NAME} still exists"
    FAIL=1
  else
    evidence "VERIFY OK: apigw domain ${DOMAIN_NAME} not-found"
  fi
  CERT_ARN="arn:aws:acm:us-east-1:${ACCOUNT}:certificate/18c59c49-1581-48b4-ba6c-402bfd3ac2d6"
  if aws acm describe-certificate --certificate-arn "$CERT_ARN" >/dev/null 2>&1; then
    evidence "NOTE: ACM cert ${CERT_ARN} still exists (imported; not stack-owned; not deleted)"
  else
    evidence "NOTE: ACM cert ${CERT_ARN} not-found"
  fi
  evidence "NOTE: DNS CNAME for ${DOMAIN_NAME} is not managed in this stack or exemem-infra; remove externally if present"
fi

evidence "Sentry: OBS_SENTRY_DSN was a committed public DSN on the Lambda; no Secrets Manager secret to delete. Stop sending by deleting the function (done above)."

if [ "$FAIL" -ne 0 ]; then
  echo "=== Teardown VERIFY failed for ${ENV_NAME} ===" >&2
  exit 1
fi
echo "=== Teardown VERIFY passed for ${ENV_NAME} ==="
