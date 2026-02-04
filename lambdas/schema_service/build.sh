#!/bin/bash
# Build schema service Lambda for deployment
set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

PROFILE=${1:-dev-release}

echo "Building schema_service Lambda (profile: $PROFILE)..."

# Build for Lambda runtime (Amazon Linux 2023)
if [ "$PROFILE" = "release" ]; then
    cargo lambda build --release --output-format zip --target x86_64-unknown-linux-gnu
else
    cargo lambda build --profile dev-release --output-format zip --target x86_64-unknown-linux-gnu
fi

# Create the extracted directory expected by CDK
TARGET_DIR="$SCRIPT_DIR/target/lambda/schema_service-extracted"
mkdir -p "$TARGET_DIR"

# Extract the bootstrap binary from the zip
unzip -o "$SCRIPT_DIR/target/lambda/schema_service/bootstrap.zip" -d "$TARGET_DIR/"

echo "Build complete: $TARGET_DIR"
ls -la "$TARGET_DIR"
