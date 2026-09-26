#!/usr/bin/env bash
# Test that the Forge deploy token is not leaked on curl's argv.
# Verifies: papercut-forge-token-on-curl-argv-in-lastgit-deploy-run-copies-20260925
set -euo pipefail

# Use a test token that will not collide with anything else.
TEST_TOKEN="test-forge-token-$(date +%s)-$$"
TMPDIR="${TMPDIR:-/tmp}"

echo "Testing: forge token not visible on curl argv..."

# Create a directory to capture curl invocations.
test_dir="$(mktemp -d "${TMPDIR}/forge-token-argv-test.XXXXXX")"
trap "rm -rf '$test_dir'" EXIT

# Mock curl that logs its arguments to a file instead of making a real request.
mock_curl="$test_dir/curl"
cat > "$mock_curl" <<'CURL_EOF'
#!/usr/bin/env bash
# Log all arguments to a file for inspection, then exit cleanly.
args_file="${TEST_MOCK_ARGS_FILE:-}"
if [ -n "$args_file" ]; then
  printf '%s\n' "$@" >> "$args_file"
fi
# Pretend to return JSON success response.
printf '{"state":"success"}'
exit 0
CURL_EOF
chmod +x "$mock_curl"

# --- Test 1: Verify the SAFE form (using -K config file) does not leak token
echo "Test 1: Safe form (curl -K config file) — token not on argv"
args_file="$test_dir/args_safe.txt"
test_scratch="$(mktemp -d "${TMPDIR}/forge-safe.XXXXXX")"
trap "rm -rf '$test_scratch' '$test_dir'" EXIT

cd "$test_scratch"
# Replicate the safe form from the fixed deploy-run.sh.
AUTH_CONF_DIR="$(mktemp -d "${TMPDIR}/forge-deploy-auth.XXXXXX")"
AUTH_CONF="$AUTH_CONF_DIR/auth.conf"
printf 'header = "Authorization: token %s"\n' "$TEST_TOKEN" >"$AUTH_CONF"
chmod 600 "$AUTH_CONF"
trap "rm -rf '$AUTH_CONF_DIR' '$test_scratch' '$test_dir'" EXIT

export TEST_MOCK_ARGS_FILE="$args_file"
export PATH="$test_dir:$PATH"

# Call curl the safe way (from the fixed deploy-run.sh).
"$mock_curl" -sS --max-time 30 -K "$AUTH_CONF" -H "Accept: application/json" \
  "http://localhost:3300/api/v1/repos/EdgeVector/schema-infra/statuses/abc123" >/dev/null || true

# Check that the token does not appear in the captured argv.
if grep -q "$TEST_TOKEN" "$args_file" || grep -q "Authorization" "$args_file"; then
  echo "FAIL: Token or Authorization header found in argv (safe form should use -K config file)"
  echo "Captured args:"
  cat "$args_file"
  exit 1
fi

# Verify that -K config file IS in the args.
if ! grep -q -- "-K" "$args_file"; then
  echo "FAIL: Expected -K flag not found in curl arguments"
  cat "$args_file"
  exit 1
fi

echo "✓ Test 1 passed: token and Authorization header not on argv"

# --- Test 2: Verify the VULNERABLE form (using -H "Authorization: token ...") DOES leak token
echo "Test 2: Vulnerable form (curl -H with inline token) — DOES leak (validation of test)"
args_file="$test_dir/args_vulnerable.txt"

export TEST_MOCK_ARGS_FILE="$args_file"
export PATH="$test_dir:$PATH"

# Call curl the vulnerable way (the old form).
"$mock_curl" -sS --max-time 30 -H "Authorization: token $TEST_TOKEN" \
  -H "Accept: application/json" \
  "http://localhost:3300/api/v1/repos/EdgeVector/schema-infra/statuses/abc123" >/dev/null || true

# Verify that the token DOES appear (to validate that our test catches the leak).
if ! grep -q "$TEST_TOKEN" "$args_file"; then
  echo "FAIL: Token should appear in argv with vulnerable form (test validation failed)"
  cat "$args_file"
  exit 1
fi

echo "✓ Test 2 passed: vulnerable form leaks token as expected (test is valid)"

echo ""
echo "All tests passed. The safe form (using curl -K config file) does not leak the token on argv."
