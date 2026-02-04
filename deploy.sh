#!/bin/bash
# Deploy schema service infrastructure
set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ENVIRONMENT="${1:-dev}"

echo "=== Deploying Schema Service Infrastructure ==="
echo "Environment: $ENVIRONMENT"
echo ""

# Build Lambda first
echo "Building Lambda..."
cd "$SCRIPT_DIR/lambdas/schema_service"
./build.sh

# Deploy CDK
echo ""
echo "Deploying CDK stack..."
cd "$SCRIPT_DIR/cdk"

# Install dependencies if needed
if [ ! -d "node_modules" ]; then
    echo "Installing CDK dependencies..."
    npm install
fi

# Deploy with environment context
npx cdk deploy "SchemaServiceStack-$ENVIRONMENT" \
    --context environment="$ENVIRONMENT" \
    --require-approval never \
    --outputs-file outputs.json

echo ""
echo "=== Deployment Complete ==="
echo "Outputs saved to: $SCRIPT_DIR/cdk/outputs.json"

# Show API URL
if [ -f outputs.json ]; then
    echo ""
    echo "Schema Service API URL:"
    cat outputs.json | grep -i "SchemaServiceApiUrl" || true
fi
