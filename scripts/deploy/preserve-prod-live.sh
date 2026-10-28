#!/usr/bin/env bash
# Read the exact existing production version before CDK publishes a candidate.
schema_prod_live_version() {
    local fn alias version
    fn="$(aws cloudformation describe-stacks --stack-name SchemaServiceStack-prod \
        --region us-east-1 --query 'Stacks[0].Outputs[?OutputKey==`SchemaServiceFunctionName`].OutputValue' --output text)" || return
    [ -n "$fn" ] && [ "$fn" != None ] || return 1
    alias="$(aws lambda get-alias --function-name "$fn" --name live --region us-east-1 \
        --query '{version:FunctionVersion,weights:RoutingConfig.AdditionalVersionWeights}' --output json)" || return
    if ! printf '%s' "$alias" | jq -e '(.weights // {} | length) == 0' >/dev/null; then
        echo "FAIL: an active production canary must finish before another CDK deployment" >&2
        return 1
    fi
    version="$(printf '%s' "$alias" | jq -er '.version | select(test("^[1-9][0-9]*$"))')" || return
    aws lambda get-function-configuration --function-name "$fn" --qualifier "$version" \
        --region us-east-1 --query Version --output text >/dev/null || return
    printf '%s\n' "$version"
}
