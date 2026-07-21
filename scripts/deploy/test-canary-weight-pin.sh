#!/usr/bin/env bash
# Unit test: canary-lib pins AdditionalVersionWeights at CANARY_WEIGHT (default 0.1).
# Drives the real set_canary_weights* helpers with a mock `aws` on PATH — not a reimplementation.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/scripts/deploy/canary-lib.sh"
test -f "$LIB" || { echo "missing $LIB" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export LASTGIT_DEPLOY_LOG_DIR="$TMP"
export CANARY_WEIGHT=0.1
export PATH="$TMP/bin:$PATH"
mkdir -p "$TMP/bin"

# Mock aws: capture update-alias invocations; get-alias returns FunctionVersion
cat >"$TMP/bin/aws" <<'AWS'
#!/usr/bin/env bash
set -euo pipefail
echo "$@" >>"${MOCK_AWS_LOG:-/dev/null}"
if [ "${1:-}" = "lambda" ] && [ "${2:-}" = "get-alias" ]; then
  # --query FunctionVersion --output text
  echo "42"
  exit 0
fi
if [ "${1:-}" = "lambda" ] && [ "${2:-}" = "update-alias" ]; then
  # record routing config arg for assertion
  printf '%s\n' "$@" >"${MOCK_AWS_UPDATE:-/dev/null}"
  exit 0
fi
# other aws calls no-op
exit 0
AWS
chmod +x "$TMP/bin/aws"
export MOCK_AWS_LOG="$TMP/aws.log"
export MOCK_AWS_UPDATE="$TMP/update-alias.args"

# shellcheck source=/dev/null
source "$LIB"

# Detect which helper exists
if declare -f set_canary_weights_one >/dev/null; then
  set_canary_weights_one "ExememAuthService-prod" "us-east-1" "100" "101"
elif declare -f set_canary_weights >/dev/null; then
  set_canary_weights "SchemaFn" "us-east-1" "5" "6"
else
  echo "no set_canary_weights helper in $LIB" >&2
  exit 1
fi

test -s "$MOCK_AWS_UPDATE" || { echo "aws update-alias was not invoked" >&2; exit 1; }
# Expect AdditionalVersionWeights={NEW=0.1}
if ! grep -q 'AdditionalVersionWeights={' "$MOCK_AWS_UPDATE"; then
  echo "missing AdditionalVersionWeights in:" >&2
  cat "$MOCK_AWS_UPDATE" >&2
  exit 1
fi
if ! grep -Eq 'AdditionalVersionWeights=\{[0-9.]+=0\.1\}' "$MOCK_AWS_UPDATE"; then
  echo "expected weight 0.1, got:" >&2
  cat "$MOCK_AWS_UPDATE" >&2
  exit 1
fi
# primary version should be OLD
if ! grep -q -- '--function-version' "$MOCK_AWS_UPDATE"; then
  echo "missing --function-version" >&2
  exit 1
fi
# no-op when old==new
: >"$MOCK_AWS_UPDATE"
if declare -f set_canary_weights_one >/dev/null; then
  if set_canary_weights_one "Fn" "us-east-1" "9" "9"; then
    echo "expected equal versions to skip weighted pin" >&2
    exit 1
  fi
else
  if set_canary_weights "Fn" "us-east-1" "9" "9"; then
    echo "expected equal versions to skip weighted pin" >&2
    exit 1
  fi
fi
if [ -s "$MOCK_AWS_UPDATE" ]; then
  echo "expected no update-alias when old==new" >&2
  cat "$MOCK_AWS_UPDATE" >&2
  exit 1
fi
echo "ok canary-weight-pin $(basename "$ROOT")"
