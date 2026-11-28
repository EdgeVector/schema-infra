#!/usr/bin/env bash
# Remove SchemaInfraDeployDev / SchemaInfraDeployProd; keep the shared OIDC provider.
#
# Run after SchemaServiceStack-dev and SchemaServiceStack-prod are gone.
# Assumes SchemaInfraDeployProd credentials (us-east-1 CDK bootstrap).
#
# The GitHub OIDC provider in SchemaInfraOidcStack is imported by
# EdgeVector/exemem-infra — destroying it would break that repo's CI.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ACCOUNT="${CDK_DEFAULT_ACCOUNT:-${AWS_ACCOUNT_ID:-152335099025}}"
export AWS_REGION="us-east-1"
export AWS_DEFAULT_REGION="us-east-1"
export CDK_DEFAULT_ACCOUNT="$ACCOUNT"
export CDK_DEFAULT_REGION="us-east-1"

STACK="SchemaInfraOidcStack"

evidence() {
  printf 'EVIDENCE[oidc] %s\n' "$*"
}

stack_status() {
  local name="$1"
  aws cloudformation describe-stacks --stack-name "$name" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "NOT_FOUND"
}

role_absent() {
  local role="$1"
  if aws iam get-role --role-name "$role" >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

cd "$ROOT/cdk"
if [ ! -d node_modules ]; then
  npm ci
fi
npm run build

STATUS="$(stack_status "$STACK")"
evidence "cloudformation ${STACK}: status=${STATUS}"

if [ "$STATUS" != "NOT_FOUND" ]; then
  evidence "cdk deploy ${STACK} with retireRoles=true (delete SchemaInfraDeploy* only)"
  npx cdk deploy "$STACK" \
    --context environment=prod \
    --context identityOnly=true \
    --context retireRoles=true \
    --require-approval never
  evidence "cdk deploy retireRoles: finished"
else
  evidence "${STACK} already absent; attempting direct IAM role delete"
  for role in SchemaInfraDeployDev SchemaInfraDeployProd; do
    if role_absent "$role"; then
      evidence "iam role ${role}: already absent"
      continue
    fi
    mapfile -t inline < <(aws iam list-role-policies --role-name "$role" \
      --query 'PolicyNames[]' --output text 2>/dev/null | tr '\t' '\n' | sed '/^$/d' || true)
    for p in "${inline[@]:-}"; do
      [ -n "$p" ] || continue
      aws iam delete-role-policy --role-name "$role" --policy-name "$p"
    done
    mapfile -t attached < <(aws iam list-attached-role-policies --role-name "$role" \
      --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null | tr '\t' '\n' | sed '/^$/d' || true)
    for arn in "${attached[@]:-}"; do
      [ -n "$arn" ] || continue
      aws iam detach-role-policy --role-name "$role" --policy-arn "$arn"
    done
    aws iam delete-role --role-name "$role"
    evidence "iam role ${role}: deleted"
  done
fi

FAIL=0
for role in SchemaInfraDeployDev SchemaInfraDeployProd; do
  if role_absent "$role"; then
    evidence "VERIFY OK: iam role ${role} not-found"
  else
    evidence "VERIFY FAIL: iam role ${role} still exists"
    FAIL=1
  fi
done

if aws iam list-open-id-connect-providers --output text 2>/dev/null \
    | grep -q 'token\.actions\.githubusercontent\.com'; then
  evidence "NOTE: GitHub Actions OIDC provider retained (shared with exemem-infra; SchemaInfraOidcStack kept)"
else
  evidence "NOTE: no GitHub Actions OIDC provider listed (unexpected if exemem-infra still deploys)"
fi

if [ "$(stack_status "$STACK")" != "NOT_FOUND" ]; then
  evidence "NOTE: ${STACK} retained to hold the shared OIDC provider (not destroyed)"
fi

if [ "$FAIL" -ne 0 ]; then
  echo "=== OIDC role teardown VERIFY failed ===" >&2
  exit 1
fi
echo "=== OIDC role teardown VERIFY passed ==="
