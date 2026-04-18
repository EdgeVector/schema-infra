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
# Bundle the fastembed model (all-MiniLM-L6-v2) into the Lambda artifact.
#
# Without this, fastembed's first call inside the Lambda tries to reach
# HuggingFace Hub, fails slowly (~200ms per retry), and falls back to a
# heuristic. That fallback wastes ~40s on the first cold-start request
# classifying built-in schema names — observed in CloudWatch for
# SchemaServiceStack-dev before this bundling was in place.
#
# Layout we produce mirrors hf_hub 0.4's cache (see:
# cargo registry/src/hf-hub-0.4.3/src/lib.rs, `pub fn get`):
#   .fastembed_cache/
#     models--Qdrant--all-MiniLM-L6-v2-onnx/
#       refs/main                               → contains revision hash
#       snapshots/<revision>/{model.onnx, tokenizer.json, ...}
#
# The Lambda sets FASTEMBED_CACHE_DIR=/var/task/.fastembed_cache and
# HF_HUB_OFFLINE=1 (see main.rs) so fastembed finds these files without
# ever touching the network.
# ---------------------------------------------------------------------------
HF_REPO="Qdrant/all-MiniLM-L6-v2-onnx"
# Pinned so a model.onnx change upstream can't silently break the Lambda
# — update this hash deliberately when you want a new model version.
HF_REVISION="5f1b8cd78bc4fb444dd171e59b18f3a3af89a079"
MODEL_FILES=(model.onnx tokenizer.json config.json special_tokens_map.json tokenizer_config.json)

CACHE_ROOT="$TARGET_DIR/.fastembed_cache/models--Qdrant--all-MiniLM-L6-v2-onnx"
SNAPSHOT_DIR="$CACHE_ROOT/snapshots/$HF_REVISION"
mkdir -p "$SNAPSHOT_DIR" "$CACHE_ROOT/refs"

# Revision pointer that hf_hub reads to locate the snapshot folder.
echo -n "$HF_REVISION" > "$CACHE_ROOT/refs/main"

echo "Downloading fastembed model files (~91MB total)..."
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
echo "Model cache prepared at $CACHE_ROOT"
ls -la "$SNAPSHOT_DIR"

echo "Build complete: $TARGET_DIR"
ls -la "$TARGET_DIR"
