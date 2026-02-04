#!/bin/bash
# Build script for schema service infrastructure
set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

echo "=== Building Schema Service Lambda ==="
cd "$SCRIPT_DIR/lambdas/schema_service"
./build.sh

echo ""
echo "=== Lambda build complete ==="
echo "Ready to deploy with: ./deploy.sh [dev|prod]"
