#!/bin/bash
# Deploy schema service infrastructure
set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ENVIRONMENT="${1:-dev}"

# Parse flags (after the first positional arg)
SKIP_INFRA=false
shift 2>/dev/null || true
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --skip-infra) SKIP_INFRA=true ;;
        --yes) YES_FLAG=true ;;
        *) echo "Unknown parameter: $1"; exit 1 ;;
    esac
    shift
done

# Determine region based on environment
if [ "$ENVIRONMENT" = "prod" ]; then
    REGION="us-east-1"
    BUILD_PROFILE="release"
else
    REGION="us-west-2"
    BUILD_PROFILE="dev-release"
fi

echo "=== Deploying Schema Service Infrastructure ==="
echo "Environment: $ENVIRONMENT"
echo "Region: $REGION"
echo "Build profile: $BUILD_PROFILE"
echo ""

# Production confirmation
if [ "$ENVIRONMENT" = "prod" ] && [ "$YES_FLAG" != "true" ]; then
    echo "WARNING: You are deploying to PRODUCTION!"
    echo ""
    read -p "Are you sure you want to continue? (yes/no): " -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        echo "Deployment cancelled"
        exit 1
    fi
fi

# Set AWS region for CDK and AWS CLI calls
export AWS_REGION="$REGION"
export AWS_DEFAULT_REGION="$REGION"

# Build Lambda (submodule-backed; see build.sh header)
echo "Building Lambda (profile: $BUILD_PROFILE)..."
"$SCRIPT_DIR/build.sh" "$BUILD_PROFILE"

# Deploy CDK
if [ "$SKIP_INFRA" = false ]; then
    echo ""
    echo "Deploying CDK stack..."
    cd "$SCRIPT_DIR/cdk"

    # Install dependencies if needed
    if [ ! -d "node_modules" ]; then
        echo "Installing CDK dependencies..."
        npm install
    fi

    npm run build

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
else
    echo ""
    echo "Skipping CDK deployment (--skip-infra)"
fi
