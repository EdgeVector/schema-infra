#!/usr/bin/env bash
# Ensure the fastembed model Layer asset exists at target/fastembed_layer
# for CDK Code.fromAsset — extracted from build.sh so the CDK deploy path
# can run with a prebuilt Lambda artifact (--skip-build) without invoking
# the whole build (release #2's 8-second CDK failure: fresh scratch had the
# zip but no layer directory).
#
# Durability: model files are mirrored in a host-side cache keyed by the
# pinned HF revision, so per-event scratch checkouts never re-download.
# HuggingFace is contacted only on a truly cold cache, with retry/backoff
# (HF 429s made a prod deploy flap 2026-06-04).
#
# The layer also carries ONNX Runtime at lib/libonnxruntime.so (/opt/lib in
# the Lambda). The function loads it at run time (fastembed
# `ort-load-dynamic`, ORT_DYLIB_PATH in cdk/lib/schema-stack.ts) instead of
# linking it into bootstrap.zip: the static copy was about 7 MB of the 15 MiB
# zip bar (decision-2026-11-03-schema-lambda-zip-stays-under-15mib).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

HF_REPO="Qdrant/all-MiniLM-L6-v2-onnx"
# Pinned so a model.onnx change upstream can't silently break the Lambda —
# update this hash deliberately when you want a new model version.
HF_REVISION="5f1b8cd78bc4fb444dd171e59b18f3a3af89a079"
MODEL_FILES=(model.onnx tokenizer.json config.json special_tokens_map.json tokenizer_config.json)

# ONNX Runtime must match the `ort` crate in the Lambda build: ort
# 2.0.0-rc.9 is ONNX Runtime 1.20 (API 20). Bump both together; an older
# runtime fails embedder init, and the Lambda then runs without embeddings.
ORT_VERSION="1.20.0"
ORT_TGZ="onnxruntime-linux-x64-${ORT_VERSION}.tgz"
ORT_TGZ_SHA256="aa70d48b22e264b82e83f63245b51ddc9a47ae4a3a66903efaff1ba68b7b5930"
ORT_LIB_SHA256="6097fe8cedc8b5b3c8e107e9c2acf04eb50f58f0f045e3d7c5c50ead38112c72"
ORT_URL="https://github.com/microsoft/onnxruntime/releases/download/v${ORT_VERSION}/${ORT_TGZ}"

LAYER_DIR="$SCRIPT_DIR/target/fastembed_layer"
CACHE_ROOT="$LAYER_DIR/fastembed_cache/models--Qdrant--all-MiniLM-L6-v2-onnx"
SNAPSHOT_DIR="$CACHE_ROOT/snapshots/$HF_REVISION"
HOST_CACHE_ROOT="${SCHEMA_LAYER_CACHE:-$HOME/.lastgit/deploy-schema-infra/fastembed-layer-cache}"
HOST_CACHE="$HOST_CACHE_ROOT/$HF_REVISION"
ORT_LIB="$LAYER_DIR/lib/libonnxruntime.so"
ORT_HOST_CACHE="$HOST_CACHE_ROOT/onnxruntime-$ORT_VERSION"

mkdir -p "$SNAPSHOT_DIR" "$CACHE_ROOT/refs" "$HOST_CACHE" "$LAYER_DIR/lib" "$ORT_HOST_CACHE"
echo -n "$HF_REVISION" > "$CACHE_ROOT/refs/main"

echo "=== Fastembed Layer ==="
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
    cached="$HOST_CACHE/$f"
    if [ -s "$target" ]; then
        echo "  [present] $f"
        continue
    fi
    if [ -s "$cached" ]; then
        cp -f "$cached" "$target"
        echo "  [host-cache] $f"
        continue
    fi
    url="https://huggingface.co/$HF_REPO/resolve/$HF_REVISION/$f"
    echo "  [download] $f"
    download_with_retry "$url" "$target" || {
        echo "ERROR: failed to download $f from HuggingFace after retries." >&2
        echo "       HF is likely rate-limiting (429); retry once it clears." >&2
        exit 1
    }
    cp -f "$target" "$cached"
done

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

# A plain file, not the release's symlink chain: CDK zips the asset directory
# and the Lambda opens the library by this exact path.
if [ -s "$ORT_LIB" ] && [ "$(sha256_of "$ORT_LIB")" = "$ORT_LIB_SHA256" ]; then
    echo "  [present] lib/libonnxruntime.so ($ORT_VERSION)"
else
    tgz="$ORT_HOST_CACHE/$ORT_TGZ"
    if [ -s "$tgz" ] && [ "$(sha256_of "$tgz")" = "$ORT_TGZ_SHA256" ]; then
        echo "  [host-cache] $ORT_TGZ"
    else
        echo "  [download] $ORT_TGZ"
        download_with_retry "$ORT_URL" "$tgz" || {
            echo "ERROR: failed to download $ORT_URL after retries." >&2
            exit 1
        }
        got="$(sha256_of "$tgz")"
        if [ "$got" != "$ORT_TGZ_SHA256" ]; then
            rm -f "$tgz"
            echo "ERROR: $ORT_TGZ sha256 $got, expected $ORT_TGZ_SHA256" >&2
            exit 1
        fi
    fi
    extract_dir="$(mktemp -d "${TMPDIR:-/tmp}/ort-layer.XXXXXX")"
    member="onnxruntime-linux-x64-${ORT_VERSION}/lib/libonnxruntime.so.${ORT_VERSION}"
    tar -xzf "$tgz" -C "$extract_dir" "$member"
    mv -f "$extract_dir/$member" "$ORT_LIB"
    rm -rf "$extract_dir"
    got="$(sha256_of "$ORT_LIB")"
    if [ "$got" != "$ORT_LIB_SHA256" ]; then
        rm -f "$ORT_LIB"
        echo "ERROR: libonnxruntime.so sha256 $got, expected $ORT_LIB_SHA256" >&2
        exit 1
    fi
    echo "  [extracted] lib/libonnxruntime.so ($ORT_VERSION)"
fi
echo "Layer dir: $LAYER_DIR"
