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
echo "Resolving Lambda function name from stack $STACK..." >&2
FN_NAME_OUTPUT=$(aws cloudformation describe-stacks \
    --stack-name "$STACK" \
    --region "$REGION" \
    --query 'Stacks[0].Outputs[?OutputKey==`SchemaServiceFunctionName`].OutputValue' \
    --output text 2>&1) || {
    echo "ERROR: Could not describe stack $STACK: $FN_NAME_OUTPUT" >&2
    exit 0  # Don't fail the capture, just skip
}

FN_NAME=$(echo "$FN_NAME_OUTPUT" | head -1)
if [ -z "$FN_NAME" ] || [ "$FN_NAME" = "None" ]; then
    echo "ERROR: Could not resolve Lambda function name from stack $STACK (got: '$FN_NAME')" >&2
    exit 0  # Don't fail the capture, just skip
fi

LOG_GROUP="/aws/lambda/$FN_NAME"

echo "== Capturing last $EVENT_LIMIT CloudWatch log events from $LOG_GROUP =="

# Capture logs from the last 10 minutes
START_TIME=$(($(date +%s) - 600))000  # 10 minutes ago in milliseconds

# Pull log events and redact secret-shaped values
# Don't hide AWS errors with 2>/dev/null - print them but don't fail
LOGS_OUTPUT=$(aws logs filter-log-events \
    --log-group-name "$LOG_GROUP" \
    --start-time "$START_TIME" \
    --limit "$EVENT_LIMIT" \
    --region "$REGION" \
    --output json 2>&1)

LOGS_RC=$?
if [ $LOGS_RC -ne 0 ]; then
    # Redact secrets from error message before printing
    echo "WARN: aws logs filter-log-events failed (exit $LOGS_RC):" >&2
    echo "$LOGS_OUTPUT" | \
        sed -E 's/(secret|password|token|key)[^[:space:]]*[:=][^[:space:]]+/\1=[REDACTED]/gi' >&2
    echo "Continuing without CloudWatch logs" >&2
    exit 0  # Don't fail the capture
fi

# Parse and redact logs
echo "$LOGS_OUTPUT" | \
    jq -r '.events[] | "\(.timestamp | todate) [\(.logStreamName)] \(.message)"' 2>/dev/null | \
    sed -E 's/("(secret|password|token|key|apikey|api_key)[^"]*"[[:space:]]*:[[:space:]]*")[^"]+(")/\1[REDACTED]\3/gi' | \
    sed -E 's/(Authorization:[[:space:]]*)[^[:space:]]+/\1[REDACTED]/gi' | \
    sed -E 's/(X-API-Key:[[:space:]]*)[^[:space:]]+/\1[REDACTED]/gi' || {
    echo "WARN: Failed to parse log events with jq" >&2
    exit 0  # Don't fail the capture
}

echo "== End of CloudWatch logs =="
