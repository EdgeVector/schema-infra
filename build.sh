#!/usr/bin/env bash
#
# Build script for schema service infrastructure.
#
# Drives the full pre-deploy artifact assembly:
#   1. Init / update the `fold/` submodule (the EdgeVector/fold monorepo,
#      pinned to main). Contains schema_service crates + fold_db crates
#      in one cargo workspace, so no sibling-fold_db checkout is needed.
#   2. Build the Lambda zip from `fold/schema_service/crates/server_lambda/`
#      (runs cargo-lambda inside Amazon Linux 2023 so ort-sys, which
#      fastembed pulls in, links against the Lambda runtime glibc).
#   3. Extract the zip to `fold/target/lambda/server_lambda-extracted/`
#      which is the path CDK reads via `Code.fromAsset(...)`.
#   4. Download the fastembed model files into `target/fastembed_layer/`
#      (at schema-infra repo root). CDK reads this via Code.fromAsset.
#
# Note: the async compile worker (`transform-compile-worker-${envName}`)
# is packaged as a Docker container image, built directly by the CDK
# deploy via `DockerImageCode.fromImageAsset(...)` pointed at
# `fold/schema_service/crates/worker/Dockerfile`. No pre-build step here —
# `cdk deploy` runs `docker build` as part of asset publishing.
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
# 1. Submodule — the fold monorepo
# =============================================================
FOLD_DIR="$SCRIPT_DIR/fold"
if [ ! -f "$FOLD_DIR/Cargo.toml" ]; then
    echo "fold submodule not initialized, running git submodule update..."
    git submodule update --init --recursive -- fold
fi
echo "fold submodule at: $(git -C "$FOLD_DIR" rev-parse --short HEAD)"

# =============================================================
# 2. Lambda build inside Docker (AL2023 == Lambda runtime)
#
# cargo-lambda's default zig-based cross-compile cannot link ort-sys
# (fastembed's ONNX Runtime). We build natively inside the AL2023
# image, so the resulting binary matches the runtime glibc exactly.
#
# Layout inside the container:
#   /build/schema-infra/         ← this repo
#   /build/schema-infra/fold/    ← submodule (fold monorepo, self-contained;
#                                  contains both schema_service and fold_db
#                                  crates as one cargo workspace)
# =============================================================
CACHE_DIR="$SCRIPT_DIR/.docker-cache"
mkdir -p "$CACHE_DIR/cargo" "$CACHE_DIR/rustup"

echo ""
echo "=== Building Lambda zip (Docker: amazonlinux:2023) ==="
docker run --rm \
    --platform linux/amd64 \
    -v "$SCRIPT_DIR":/build/schema-infra \
    -w /build/schema-infra/fold \
    -e CARGO_HOME=/build/schema-infra/.docker-cache/cargo \
    -e RUSTUP_HOME=/build/schema-infra/.docker-cache/rustup \
    -e BUILD_PROFILE="$PROFILE" \
    -e GH_PAT="${GH_PAT:-}" \
    amazonlinux:2023 \
    bash -c '
        set -euo pipefail
        yum install -y gcc gcc-c++ cmake3 openssl-devel pkg-config tar gzip bzip2-libs perl git > /dev/null 2>&1
        # Cargo needs to fetch private cross-repo git deps (e.g.
        # exemem_common from EdgeVector/exemem-infra). Conditional on
        # GH_PAT so local builds (no token) still work for fully-public-dep
        # cases.
        if [ -n "${GH_PAT:-}" ]; then
            git config --global url."https://x-access-token:${GH_PAT}@github.com/".insteadOf "https://github.com/"
        fi
        if [ ! -x /build/schema-infra/.docker-cache/cargo/bin/cargo ]; then
            curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable 2>&1 | tail -1
        fi
        export PATH="/build/schema-infra/.docker-cache/cargo/bin:$PATH"
        if ! command -v cargo-lambda >/dev/null 2>&1; then
            # NOTE: this whole block runs inside a single-quoted bash -c
            # string, so comments here must avoid apostrophes.
            # --locked compiles cargo-lambda against ITS OWN published
            # Cargo.lock, not a fresh registry resolve. This is the line that
            # actually broke the deploy 2026-06-12: on a cache miss the
            # container recompiles cargo-lambda from source, and an unlocked
            # resolve pulled time 0.3.48 (E0119 under stable rustc), exit 101
            # BEFORE the schema_service build (and its --locked) ever ran.
            # The cargo-lambda release ships a known-good lock; honor it, and
            # pin the version so the tool stays reproducible.
            cargo install cargo-lambda --version 1.9.1 --locked 2>&1 | tail -1
        fi
        # --locked: build against fold's committed Cargo.lock instead of
        # re-resolving. Without it the AL2023 build picks up whatever the
        # registry serves that day — which broke the deploy 2026-06-12 when
        # `time 0.3.48` shipped (E0119 conflicting From impls under stable
        # rustc). fold pins `time 0.3.47`; honor it. Resolution drift now
        # fails as a deliberate lockfile bump, not a silent prod-deploy
        # outage. (cargo-lambda forwards unknown flags through to cargo.)
        cargo lambda build \
            --profile "${BUILD_PROFILE}" \
            --output-format zip \
            --target x86_64-unknown-linux-gnu \
            --compiler cargo \
            --locked \
            -p schema_service_server_lambda
        chmod -R a+rwX target/lambda/ 2>/dev/null || true
    '

# =============================================================
# 3. Extract bootstrap.zip for CDK Code.fromAsset(...)
# =============================================================
ZIP_PATH="$FOLD_DIR/target/lambda/server_lambda/bootstrap.zip"
EXTRACTED_DIR="$FOLD_DIR/target/lambda/server_lambda-extracted"

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
# Durability: the model files are cached across CI runs by GitHub Actions
# cache (see deploy.yml's "Cache fastembed model" step, keyed on the pinned
# HF_REVISION). On a cache HIT the files are already present below and we skip
# the network entirely — HuggingFace is only ever contacted on a cold cache
# (first run, a deliberate revision bump, or a ~7-day cache eviction). When we
# DO hit the network, HF rate-limits CI runners hard (HTTP 429) — a single
# bare `curl` made the whole prod deploy flap (4 consecutive 429 failures,
# 2026-06-04). So the cold path retries with exponential backoff.
download_with_retry() {
    local url="$1" target="$2"
    local attempts=6 delay=5 i
    for ((i = 1; i <= attempts; i++)); do
        if curl -fsSL -o "$target" "$url"; then
            return 0
        fi
        rm -f "$target"
        echo "    attempt $i/$attempts failed; retrying in ${delay}s" >&2
        [ "$i" -lt "$attempts" ] && sleep "$delay" && delay=$((delay * 2))
    done
    return 1
}
for f in "${MODEL_FILES[@]}"; do
    target="$SNAPSHOT_DIR/$f"
    if [ -s "$target" ]; then
        echo "  [cached] $f"
        continue
    fi
    url="https://huggingface.co/$HF_REPO/resolve/$HF_REVISION/$f"
    echo "  [download] $f"
    download_with_retry "$url" "$target" || {
        echo "ERROR: failed to download $f from HuggingFace after retries." >&2
        echo "       HF is likely rate-limiting (429). The GitHub Actions cache" >&2
        echo "       (deploy.yml) normally serves this so HF is rarely hit; if" >&2
        echo "       this is a cold cache, re-run once the rate limit clears." >&2
        exit 1
    }
done
echo "Layer dir: $LAYER_DIR"
ls -la "$SNAPSHOT_DIR"

echo ""
echo "=== Build complete ==="
echo "Ready to deploy with: ./deploy.sh [dev|prod]"
