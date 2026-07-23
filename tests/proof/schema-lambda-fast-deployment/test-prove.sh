#!/usr/bin/env bash
# Self-check for the schema-lambda-fast-deployment terminal proof harness.
# Proves fail-closed behavior and PASS only with complete fixtures.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PROVE="$ROOT/scripts/proof/schema-lambda-fast-deployment/prove.sh"
FIXTURES="$ROOT/tests/proof/schema-lambda-fast-deployment/fixtures"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

[ -x "$PROVE" ] || chmod +x "$PROVE"
command -v python3 >/dev/null || { echo "FAIL: python3 required" >&2; exit 1; }

expect_fail() {
  local name="$1"
  shift
  local report="$TMP/${name}.md"
  set +e
  "$@" --report "$report" >"$TMP/${name}.out" 2>"$TMP/${name}.err"
  local rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    echo "FAIL: expected $name to fail closed (exit 0)" >&2
    cat "$TMP/${name}.out" "$TMP/${name}.err" >&2 || true
    exit 1
  fi
  [ -f "$report" ] || { echo "FAIL: $name wrote no report" >&2; exit 1; }
  local first
  first="$(head -n 1 "$report")"
  if [ "$first" != "FAIL" ]; then
    echo "FAIL: $name report first line want FAIL got '$first'" >&2
    exit 1
  fi
  echo "ok fail-closed: $name"
}

expect_pass() {
  local name="$1"
  shift
  local report="$TMP/${name}.md"
  set +e
  "$@" --report "$report" >"$TMP/${name}.out" 2>"$TMP/${name}.err"
  local rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: expected $name to PASS (exit $rc)" >&2
    cat "$TMP/${name}.out" "$TMP/${name}.err" >&2 || true
    exit 1
  fi
  local first
  first="$(head -n 1 "$report")"
  if [ "$first" != "PASS" ]; then
    echo "FAIL: $name report first line want PASS got '$first'" >&2
    exit 1
  fi
  grep -q "p95 artifact" "$report" || {
    echo "FAIL: $name report missing p95 timing section" >&2
    exit 1
  }
  # Must not contain raw secret patterns in a PASS report.
  if grep -Eiq 'aws_secret_access_key|BEGIN (RSA |EC )?PRIVATE KEY|AKIA[0-9A-Z]{16}' "$report"; then
    echo "FAIL: $name PASS report appears secret-bearing" >&2
    exit 1
  fi
  echo "ok pass: $name"
}

# 1) No evidence directory → FAIL
expect_fail missing-evidence \
  env -u SCHEMA_LAMBDA_PROOF_EVIDENCE \
  "$PROVE" --repo-root "$ROOT" --evidence-dir "$TMP/does-not-exist"

# 2) Incomplete fixture → FAIL
expect_fail incomplete \
  "$PROVE" --repo-root "$ROOT" --evidence-dir "$FIXTURES/incomplete"

# 3) Secret-bearing fixture → FAIL
expect_fail secret-bearing \
  "$PROVE" --repo-root "$ROOT" --evidence-dir "$FIXTURES/secret-bearing"

# 4) Digest mismatch → FAIL
expect_fail digest-mismatch \
  "$PROVE" --repo-root "$ROOT" --evidence-dir "$FIXTURES/digest-mismatch"

# 5) Complete fixture → PASS
expect_pass complete \
  "$PROVE" --repo-root "$ROOT" --evidence-dir "$FIXTURES/complete"

# 6) Default path without evidence must not invent PASS
DEFAULT_REPORT="$TMP/default-no-evidence.md"
set +e
env -u SCHEMA_LAMBDA_PROOF_EVIDENCE \
  "$PROVE" --repo-root "$ROOT" \
  --evidence-dir "$ROOT/target/schema-lambda-fast-deployment-evidence-missing-$$" \
  --report "$DEFAULT_REPORT" \
  >"$TMP/default.out" 2>"$TMP/default.err"
rc=$?
set -e
[ "$rc" -ne 0 ] || { echo "FAIL: default missing evidence should fail" >&2; exit 1; }
[ "$(head -n 1 "$DEFAULT_REPORT")" = "FAIL" ] || {
  echo "FAIL: default missing evidence report must start with FAIL" >&2
  exit 1
}

echo "ok schema-lambda-fast-deployment proof harness"
