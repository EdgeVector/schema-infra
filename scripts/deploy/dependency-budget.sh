#!/usr/bin/env bash
# Emit a secret-safe dependency and artifact identity snapshot.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/deploy/telemetry.sh
source "$ROOT/scripts/deploy/telemetry.sh"

sha256_file() {
  local path="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
  else
    sha256sum "$path" | awk '{print $1}'
  fi
}

file_size() {
  local path="$1"
  stat -f%z "$path" 2>/dev/null || stat -c%s "$path"
}

short_git_oid() {
  local dir="$1"
  git -C "$dir" rev-parse --short=12 HEAD 2>/dev/null || printf 'unknown'
}

normal_package_count() {
  local lock="$1"
  if [ ! -f "$lock" ]; then
    printf 'missing'
    return 0
  fi
  awk '
    /^\[\[package\]\]$/ { in_package=1; next }
    in_package && /^name = / {
      gsub(/^name = "/, "", $0)
      gsub(/"$/, "", $0)
      names[$0]=1
      in_package=0
    }
    END {
      for (name in names) count++
      print count + 0
    }
  ' "$lock"
}

FOLD_DIR="$ROOT/fold"
LOCK_PATH="$FOLD_DIR/Cargo.lock"
ZIP_PATH="$FOLD_DIR/target/lambda/server_lambda/bootstrap.zip"

cargo_lock_sha="missing"
if [ -f "$LOCK_PATH" ]; then
  cargo_lock_sha="$(sha256_file "$LOCK_PATH")"
fi

bootstrap_sha="missing"
bootstrap_size_bytes="missing"
if [ -f "$ZIP_PATH" ]; then
  bootstrap_sha="$(sha256_file "$ZIP_PATH")"
  bootstrap_size_bytes="$(file_size "$ZIP_PATH")"
fi

schema_telemetry_emit dependency_budget \
  "fold_oid=$(short_git_oid "$FOLD_DIR")" \
  "cargo_lock_sha256=$cargo_lock_sha" \
  "normal_package_count=$(normal_package_count "$LOCK_PATH")" \
  "bootstrap_zip_sha256=$bootstrap_sha" \
  "bootstrap_zip_size_bytes=$bootstrap_size_bytes"
