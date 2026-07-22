#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
PROBE="$ROOT/scripts/deploy/prove-mutation-gate.sh"
BOUNDED="$ROOT/scripts/deploy/bounded-command.py"

bash "$PROBE" --help >/dev/null

if bash "$PROBE" --environment prod >/dev/null 2>&1; then
  echo "FAIL: production ran without --allow-prod" >&2
  exit 1
fi
if bash "$PROBE" --environment prod --allow-prod --quota-probe >/dev/null 2>&1; then
  echo "FAIL: production accepted --quota-probe" >&2
  exit 1
fi
if bash "$PROBE" --max-quota-attempts 0 >/dev/null 2>&1; then
  echo "FAIL: zero quota attempts accepted" >&2
  exit 1
fi
if bash "$PROBE" --max-quota-attempts 25 >/dev/null 2>&1; then
  echo "FAIL: excessive quota attempts accepted" >&2
  exit 1
fi

grep -F -- '--quota-attempts "$MAX_QUOTA_ATTEMPTS"' "$PROBE" >/dev/null
if grep -F -- 'quota-${START_EPOCH}-${QUOTA_ATTEMPTS}' "$PROBE" >/dev/null; then
  echo "FAIL: per-process quota loop returned" >&2
  exit 1
fi

# AWS CLI text queries are evaluated once per paginated response and can emit
# multiple integer lines. The live proof must aggregate the JSON event array
# before comparing the count as a shell integer.
grep -F -- '--output json |' "$PROBE" >/dev/null
grep -F "jq -r '.events | length'" "$PROBE" >/dev/null

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/schema-pow-bounded-test.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

python3 "$BOUNDED" --phase success-case --timeout-seconds 2 --progress-seconds 1 \
  --stdout-file "$tmp_dir/success.out" --stderr-file "$tmp_dir/success.err" -- \
  sh -c 'printf success-output; printf private-diagnostic >&2'
[ "$(cat "$tmp_dir/success.out")" = "success-output" ] || {
  echo "FAIL: bounded command did not capture stdout" >&2
  exit 1
}

set +e
python3 "$BOUNDED" --phase timeout-case --timeout-seconds 1 --progress-seconds 1 \
  --stdout-file "$tmp_dir/timeout.out" --stderr-file "$tmp_dir/timeout.err" -- \
  sh -c 'printf secret-timeout-diagnostic >&2; sleep 5' \
  2>"$tmp_dir/helper.err"
timeout_status=$?
set -e
[ "$timeout_status" -eq 124 ] || {
  echo "FAIL: bounded command timeout returned $timeout_status, expected 124" >&2
  exit 1
}
grep -F 'phase=timeout-case exceeded timeout_seconds=1' "$tmp_dir/helper.err" >/dev/null
if grep -F 'secret-timeout-diagnostic' "$tmp_dir/helper.err" >/dev/null; then
  echo "FAIL: bounded command leaked captured stderr" >&2
  exit 1
fi

grep -F -- '--phase real-client-proof' "$PROBE" >/dev/null
grep -F -- '--phase quota-client-proof' "$PROBE" >/dev/null

echo "ok mutation-gate proof guards"
