#!/usr/bin/env bash
#
# Build script for schema service infrastructure.
#
# Drives the full pre-deploy artifact assembly:
#   1. Init / update the `schema_service/` submodule (pinned to main).
#   2. Build the Lambda zip from `schema_service/crates/server_lambda/`
#      (runs cargo-lambda inside Amazon Linux 2023 so ort-sys, which
#      fastembed pulls in, links against the Lambda runtime glibc).
#   3. Extract the zip to `schema_service/target/lambda/server_lambda-extracted/`
#      which is the path CDK reads via `Code.fromAsset(...)`.
#   4. Download the fastembed model files into `target/fastembed_layer/`
#      (at schema-infra repo root). CDK reads this via Code.fromAsset.
#
# Note: the async compile worker (`transform-compile-worker-${envName}`)
# is packaged as a Docker container image, built directly by the CDK
# deploy via `DockerImageCode.fromImageAsset(...)` pointed at
# `schema_service/crates/worker/Dockerfile`. No pre-build step here —
# `cdk deploy` runs `docker build` as part of asset publishing. See
# `projects/transform-worker-split` in gbrain for rationale.
#
# Usage:
#   ./build.sh                    # release build
#   ./build.sh dev-release        # faster iteration profile
#   BUILD_PROFILE=dev-release ./build.sh
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

PROFILE="${1:-${BUILD_PROFILE:-release}}"

echo "=== Schema Service artifact build ==="
echo "Profile: $PROFILE"
echo ""

# =============================================================
# 1. Submodule — the schema_service repo
# =============================================================
SCHEMA_SERVICE_DIR="$SCRIPT_DIR/schema_service"
if [ ! -f "$SCHEMA_SERVICE_DIR/Cargo.toml" ]; then
    echo "schema_service submodule not initialized, running git submodule update..."
    git submodule update --init --recursive -- schema_service
fi
echo "schema_service submodule at: $(git -C "$SCHEMA_SERVICE_DIR" rev-parse --short HEAD)"

# =============================================================
# 2. Lambda build inside Docker (AL2023 == Lambda runtime)
#
# cargo-lambda's default zig-based cross-compile cannot link ort-sys
# (fastembed's ONNX Runtime). We build natively inside the AL2023
# image, so the resulting binary matches the runtime glibc exactly.
#
# Layout inside the container:
#   /build/schema-infra/              ← this repo
#   /build/schema-infra/schema_service/ ← submodule (mounted via parent)
#   /build/schema-infra/fold_db/      ← workspace fold_db, mounted so the
#                                       submodule's `.cargo/config.toml`
#                                       patch `path = "../fold_db"` resolves.
# =============================================================
WORKSPACE_FOLD_DB="$(cd "$SCRIPT_DIR/../fold_db" 2>/dev/null && pwd -P || true)"
if [ -z "$WORKSPACE_FOLD_DB" ] || [ ! -d "$WORKSPACE_FOLD_DB" ]; then
    echo "ERROR: workspace fold_db not found at $SCRIPT_DIR/../fold_db"
    echo "       Build requires the exemem-workspace layout so the schema_service"
    echo "       submodule's .cargo/config.toml patch can resolve fold_db locally."
    exit 1
fi
echo "Using workspace fold_db from: $WORKSPACE_FOLD_DB"

CACHE_DIR="$SCRIPT_DIR/.docker-cache"
mkdir -p "$CACHE_DIR/cargo" "$CACHE_DIR/rustup"

echo ""
echo "=== Building Lambda zip (Docker: amazonlinux:2023) ==="
docker run --rm \
    --platform linux/amd64 \
    -v "$SCRIPT_DIR":/build/schema-infra \
    -v "$WORKSPACE_FOLD_DB":/build/schema-infra/fold_db \
    -w /build/schema-infra/schema_service \
    -e CARGO_HOME=/build/schema-infra/.docker-cache/cargo \
    -e RUSTUP_HOME=/build/schema-infra/.docker-cache/rustup \
    -e BUILD_PROFILE="$PROFILE" \
    amazonlinux:2023 \
    bash -c '
        set -euo pipefail
        yum install -y gcc gcc-c++ cmake3 openssl-devel pkg-config tar gzip bzip2-libs perl > /dev/null 2>&1
        if [ ! -x /build/schema-infra/.docker-cache/cargo/bin/cargo ]; then
            curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable 2>&1 | tail -1
        fi
        export PATH="/build/schema-infra/.docker-cache/cargo/bin:$PATH"
        if ! command -v cargo-lambda >/dev/null 2>&1; then
            cargo install cargo-lambda 2>&1 | tail -1
        fi
        cargo lambda build \
            --profile "${BUILD_PROFILE}" \
            --output-format zip \
            --target x86_64-unknown-linux-gnu \
            --compiler cargo \
            -p schema_service_server_lambda
        chmod -R a+rwX target/lambda/ 2>/dev/null || true
    '

# =============================================================
# 3. Extract bootstrap.zip for CDK Code.fromAsset(...)
# =============================================================
ZIP_PATH="$SCHEMA_SERVICE_DIR/target/lambda/server_lambda/bootstrap.zip"
EXTRACTED_DIR="$SCHEMA_SERVICE_DIR/target/lambda/server_lambda-extracted"

if [ ! -f "$ZIP_PATH" ]; then
    echo "ERROR: Lambda build did not produce $ZIP_PATH"
    exit 1
fi

rm -rf "$EXTRACTED_DIR"
mkdir -p "$EXTRACTED_DIR"
unzip -o "$ZIP_PATH" -d "$EXTRACTED_DIR/" > /dev/null

SIZE_MB=$(( $(stat -f%z "$ZIP_PATH" 2>/dev/null || stat -c%s "$ZIP_PATH") / 1024 / 1024 ))
echo ""
echo "=== Lambda artifact ==="
echo "Zip:       $ZIP_PATH (${SIZE_MB}MB)"
echo "Extracted: $EXTRACTED_DIR"
ls -la "$EXTRACTED_DIR"

# =============================================================
# 4. Fastembed Layer — download model files into the Layer
#    artifact directory CDK reads via lambda.Code.fromAsset.
#
# Per Phase 1 D2 the Layer source lives in schema-infra (this repo)
# because the Layer is a deploy concern. Output path is
# target/fastembed_layer/ at the repo root.
# =============================================================
HF_REPO="Qdrant/all-MiniLM-L6-v2-onnx"
# Pinned so a model.onnx change upstream can't silently break the Lambda —
# update this hash deliberately when you want a new model version.
HF_REVISION="5f1b8cd78bc4fb444dd171e59b18f3a3af89a079"
MODEL_FILES=(model.onnx tokenizer.json config.json special_tokens_map.json tokenizer_config.json)

LAYER_DIR="$SCRIPT_DIR/target/fastembed_layer"
CACHE_ROOT="$LAYER_DIR/fastembed_cache/models--Qdrant--all-MiniLM-L6-v2-onnx"
SNAPSHOT_DIR="$CACHE_ROOT/snapshots/$HF_REVISION"
mkdir -p "$SNAPSHOT_DIR" "$CACHE_ROOT/refs"
echo -n "$HF_REVISION" > "$CACHE_ROOT/refs/main"

echo ""
echo "=== Fastembed Layer ==="
for f in "${MODEL_FILES[@]}"; do
    target="$SNAPSHOT_DIR/$f"
    if [ -s "$target" ]; then
        echo "  [cached] $f"
        continue
    fi
    url="https://huggingface.co/$HF_REPO/resolve/$HF_REVISION/$f"
    echo "  [download] $f"
    curl -fsSL -o "$target" "$url" || { echo "ERROR: failed to download $f"; exit 1; }
done
echo "Layer dir: $LAYER_DIR"
ls -la "$SNAPSHOT_DIR"

echo ""
echo "=== Build complete ==="
echo "Ready to deploy with: ./deploy.sh [dev|prod]"
