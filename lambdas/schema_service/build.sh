#!/bin/bash
# Build schema service Lambda for deployment
set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

PROFILE=${1:-dev-release}

echo "Building schema_service Lambda (profile: $PROFILE)..."

# Build for Lambda runtime (Amazon Linux 2023) inside Docker.
# Docker is required because fastembed (ONNX Runtime) can't cross-compile from macOS to Linux.
# The Cargo.toml references fold_db via path = "../../../fold_db", so we mount the
# common ancestor directory to preserve the relative path layout.

# Resolve fold_db (may be a symlink)
FOLD_DB_REAL="$(cd "$SCRIPT_DIR/../../../fold_db" 2>/dev/null && pwd -P)"
if [ ! -d "$FOLD_DB_REAL" ]; then
    echo "ERROR: fold_db not found at $SCRIPT_DIR/../../../fold_db"
    exit 1
fi
echo "Using fold_db from: $FOLD_DB_REAL"

# Mount schema-infra and fold_db into a layout that matches the relative path
# schema_service is at /build/schema-infra/lambdas/schema_service
# fold_db needs to be at /build/fold_db (i.e., ../../../fold_db relative to schema_service)
SCHEMA_INFRA_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Build inside Amazon Linux 2023 (same as Lambda runtime) to ensure glibc compatibility.
# The cargo-lambda Docker image uses zig linker which can't link ort-sys (ONNX),
# so we install Rust + cargo-lambda in an AL2023 container and build natively.
docker run --rm \
    --platform linux/amd64 \
    -v "$SCHEMA_INFRA_DIR":/build/schema-infra \
    -v "$FOLD_DB_REAL":/build/fold_db \
    -w /build/schema-infra/lambdas/schema_service \
    -e CARGO_HOME=/build/schema-infra/lambdas/schema_service/.docker-cargo \
    -e RUSTUP_HOME=/build/schema-infra/lambdas/schema_service/.docker-rustup \
    amazonlinux:2023 \
    bash -c '
        yum install -y gcc gcc-c++ cmake3 openssl-devel pkg-config tar gzip bzip2-libs perl > /dev/null 2>&1
        curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable 2>&1 | tail -1
        export PATH="/build/schema-infra/lambdas/schema_service/.docker-cargo/bin:$PATH"
        cargo install cargo-lambda 2>&1 | tail -1
        cargo lambda build --profile '"$PROFILE"' --output-format zip --compiler cargo
        # Fix permissions so host user can access build artifacts
        chmod -R a+rwX target/lambda/ 2>/dev/null || true
    '

# Create the extracted directory expected by CDK
TARGET_DIR="$SCRIPT_DIR/target/lambda/schema_service-extracted"
mkdir -p "$TARGET_DIR"

# Extract the bootstrap binary from the zip
unzip -o "$SCRIPT_DIR/target/lambda/schema_service/bootstrap.zip" -d "$TARGET_DIR/"

# ---------------------------------------------------------------------------
# Bundle the fastembed model (all-MiniLM-L6-v2) into a SEPARATE Lambda Layer
# artifact — NOT the function zip.
#
# Why a Layer rather than the function zip:
# - Layer is uploaded once per model-version change, not on every code edit.
# - Function zip stays ~20MB, so function deploys are fast.
# - AWS mounts layer contents at /opt/, so the Lambda reads the model
#   from /opt/fastembed_cache/... with no filesystem copy at runtime.
#
# Why bundle rather than download at runtime: cold-start reliability. The
# original behavior (fastembed pulls from HuggingFace on first use) fails
# slowly (~200ms per retry) and falls back to heuristics — wasting 40s
# of first-request time classifying ~200 built-in schema fields.
#
# Layout mirrors hf_hub 0.4's cache (see hf-hub-0.4.3/src/lib.rs `pub fn get`):
#   fastembed_cache/
#     models--Qdrant--all-MiniLM-L6-v2-onnx/
#       refs/main                               → revision hash
#       snapshots/<revision>/{model.onnx, tokenizer.json, ...}
#
# Layer filesystem root maps to /opt/, so the Lambda sets:
#   FASTEMBED_CACHE_DIR=/opt/fastembed_cache
#   HF_HUB_OFFLINE=1
# and fastembed finds the files without ever touching the network.
#
# No leading dot on `fastembed_cache` — actions/upload-artifact@v4
# excludes hidden entries by default, which silently drops bundled files
# between CI jobs (observed on run 24613753418 for the pre-Layer design).
# ---------------------------------------------------------------------------
HF_REPO="Qdrant/all-MiniLM-L6-v2-onnx"
# Pinned so a model.onnx change upstream can't silently break the Lambda
# — update this hash deliberately when you want a new model version.
HF_REVISION="5f1b8cd78bc4fb444dd171e59b18f3a3af89a079"
MODEL_FILES=(model.onnx tokenizer.json config.json special_tokens_map.json tokenizer_config.json)

LAYER_DIR="$SCRIPT_DIR/target/lambda/fastembed_layer"
CACHE_ROOT="$LAYER_DIR/fastembed_cache/models--Qdrant--all-MiniLM-L6-v2-onnx"
SNAPSHOT_DIR="$CACHE_ROOT/snapshots/$HF_REVISION"
mkdir -p "$SNAPSHOT_DIR" "$CACHE_ROOT/refs"

# Revision pointer that hf_hub reads to locate the snapshot folder.
echo -n "$HF_REVISION" > "$CACHE_ROOT/refs/main"

echo "Downloading fastembed model files (~91MB total) into Layer artifact..."
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
echo "Layer artifact prepared at $LAYER_DIR"
ls -la "$SNAPSHOT_DIR"

echo "Function artifact: $TARGET_DIR"
ls -la "$TARGET_DIR"
echo "Layer artifact:    $LAYER_DIR"
