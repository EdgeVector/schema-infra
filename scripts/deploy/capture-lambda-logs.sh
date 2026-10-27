#!/usr/bin/env bash
# Capture CloudWatch logs from the dev Lambda when smoke tests fail.
# Prints the last ~200 log events, redacting secret-shaped values.
set -euo pipefail

ENVIRONMENT="${1:-dev}"
REGION="${2:-us-west-2}"
EVENT_LIMIT="${3:-200}"

if [ "$ENVIRONMENT" != "dev" ]; then
    echo "Log capture only runs on dev environment" >&2
    exit 0
fi

STACK="SchemaServiceStack-$ENVIRONMENT"

# Resolve Lambda function name from stack outputs
FN_NAME=$(aws cloudformation describe-stacks \
    --stack-name "$STACK" \
    --region "$REGION" \
    --query 'Stacks[0].Outputs[?OutputKey==`SchemaServiceFunctionName`].OutputValue' \
    --output text 2>/dev/null || echo "")

if [ -z "$FN_NAME" ] || [ "$FN_NAME" = "None" ]; then
    echo "ERROR: Could not resolve Lambda function name from stack $STACK" >&2
    exit 1
fi

LOG_GROUP="/aws/lambda/$FN_NAME"

echo "== Capturing last $EVENT_LIMIT CloudWatch log events from $LOG_GROUP =="

# Capture logs from the last 10 minutes
START_TIME=$(($(date +%s) - 600))000  # 10 minutes ago in milliseconds

# Pull log events and redact secret-shaped values
aws logs filter-log-events \
    --log-group-name "$LOG_GROUP" \
    --start-time "$START_TIME" \
    --limit "$EVENT_LIMIT" \
    --region "$REGION" \
    --output json 2>/dev/null | \
    jq -r '.events[] | "\(.timestamp | todate) [\(.logStreamName)] \(.message)"' | \
    sed -E 's/("(secret|password|token|key|apikey|api_key)[^"]*"[[:space:]]*:[[:space:]]*")[^"]+(")/\1[REDACTED]\3/gi' | \
    sed -E 's/(Authorization:[[:space:]]*)[^[:space:]]+/\1[REDACTED]/gi' | \
    sed -E 's/(X-API-Key:[[:space:]]*)[^[:space:]]+/\1[REDACTED]/gi' || {
    echo "ERROR: Failed to fetch CloudWatch logs. Check IAM permissions for logs:FilterLogEvents" >&2
    exit 1
}

echo "== End of CloudWatch logs =="
