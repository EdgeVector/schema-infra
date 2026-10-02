#!/usr/bin/env bash
# Proof: a canary alarm rolls the schema live alias back to FunctionVersion
# and opens one GitHub issue. A missing alarm, an empty weight map, a deleted
# FunctionVersion, and a non-0.05 weight map must not change the alias.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
LIB="$ROOT/scripts/deploy/canary-lib.sh"
TICKER="$ROOT/.lastgit/canary-ticker.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/canary-alarm-loop.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export LASTGIT_DEPLOY_LOG_DIR="$TMP/state"
export CANARY_ALIAS_FN="SchemaFn"
export CANARY_ALIAS_REGION="us-east-1"
export SCHEMA_CANARY_ALERT_NOTICE=0
export SCHEMA_CANARY_OPEN_ISSUE=1
export SCHEMA_CANARY_ISSUE_REPO="EdgeVector/schema-infra"
export GITHUB_REPOSITORY="EdgeVector/schema-infra"
export GITHUB_STEP_SUMMARY="$TMP/step-summary.md"
export GH_TOKEN="test-token"
export PATH="$TMP/bin:$PATH"
mkdir -p "$TMP/bin" "$TMP/state"

if grep -nE '(^|[[:space:]])kanban([[:space:]]|$)' "$LIB" "$TICKER"; then
  echo "ticker must not call kanban" >&2
  exit 1
fi

cat >"$TMP/alias.json" <<'EOF'
{
  "FunctionVersion": "12",
  "LastModified": "2026-10-01T00:00:00.000+0000",
  "RoutingConfig": {"AdditionalVersionWeights": {"13": 0.05}}
}
EOF
export CANARY_ALIAS_FIXTURE="$TMP/alias.json"

cat >"$TMP/bin/aws" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${MOCK_AWS_LOG}"
if [ "${1:-}" = "cloudwatch" ] && [ "${2:-}" = "describe-alarms" ]; then
  name=""
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "--alarm-names" ]; then name="${2:-}"; break; fi
    shift
  done
  case "${MOCK_ALARM_MODE:-ok}:$name" in
    alarm-quota:schema-mutation-gate-hourly-quota-prod) printf '%s\n' ALARM ;;
    alarm-quota:*) printf '%s\n' OK ;;
    alarm-error:schema-mutation-gate-internal-error-prod) printf '%s\n' ALARM ;;
    alarm-error:*) printf '%s\n' OK ;;
    missing:schema-mutation-gate-hourly-quota-prod) printf '%s\n' None ;;
    missing:*) printf '%s\n' OK ;;
    insufficient:*) printf '%s\n' INSUFFICIENT_DATA ;;
    *) printf '%s\n' OK ;;
  esac
  exit 0
fi
if [ "${1:-}" = "lambda" ] && [ "${2:-}" = "get-function" ]; then
  if [ -n "${MOCK_MISSING_VERSION:-}" ]; then
    case "$*" in *":${MOCK_MISSING_VERSION} "*|*":${MOCK_MISSING_VERSION}") exit 254 ;; esac
  fi
  exit 0
fi
if [ "${1:-}" = "lambda" ] && [ "${2:-}" = "update-alias" ]; then
  printf '%s\n' "$*" >>"${MOCK_AWS_UPDATE}"
  exit 0
fi
if [ "${1:-}" = "lambda" ] && [ "${2:-}" = "list-versions-by-function" ]; then
  echo "list-versions-by-function must not run" >&2
  exit 99
fi
if [ "${1:-}" = "lambda" ] && [ "${2:-}" = "get-alias" ]; then
  exit 0
fi
exit 0
EOF
chmod +x "$TMP/bin/aws"

cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${MOCK_GH_LOG}"
if [ "${1:-}" = "label" ]; then
  exit 0
fi
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "create" ]; then
  if [ "${MOCK_GH_FAIL:-}" = "1" ]; then
    exit 1
  fi
  printf '%s\n' "$@" >"${MOCK_GH_CREATE}"
  prev=""
  for a in "$@"; do
    if [ "$prev" = "--body-file" ]; then
      cp "$a" "${MOCK_GH_BODY}"
    fi
    prev="$a"
  done
  echo "https://github.com/EdgeVector/schema-infra/issues/42"
  exit 0
fi
exit 0
EOF
chmod +x "$TMP/bin/gh"

cat >"$TMP/bin/kanban" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "kanban $*" >>"${MOCK_KANBAN_LOG}"
exit 99
EOF
chmod +x "$TMP/bin/kanban"

export MOCK_AWS_LOG="$TMP/aws.log"
export MOCK_AWS_UPDATE="$TMP/update"
export MOCK_GH_LOG="$TMP/gh.log"
export MOCK_GH_CREATE="$TMP/gh-create"
export MOCK_GH_BODY="$TMP/gh-body"
export MOCK_KANBAN_LOG="$TMP/kanban.log"
: >"$MOCK_AWS_LOG"
: >"$MOCK_AWS_UPDATE"
: >"$MOCK_GH_LOG"
: >"$MOCK_KANBAN_LOG"
: >"$GITHUB_STEP_SUMMARY"

# shellcheck source=/dev/null
source "$LIB"

assert_no_update() {
  if [ -s "$MOCK_AWS_UPDATE" ]; then
    echo "$1" >&2
    cat "$MOCK_AWS_UPDATE" >&2
    exit 1
  fi
}

assert_no_issue() {
  if grep -q 'issue create' "$MOCK_GH_LOG"; then
    echo "$1" >&2
    cat "$MOCK_GH_LOG" >&2
    exit 1
  fi
}

assert_no_kanban() {
  if [ -s "$MOCK_KANBAN_LOG" ]; then
    echo "ticker must not call kanban:" >&2
    cat "$MOCK_KANBAN_LOG" >&2
    exit 1
  fi
}

# 1. Missing configured alarm: non-zero, alias unchanged, no issue.
: >"$MOCK_AWS_UPDATE"
: >"$MOCK_GH_LOG"
: >"$MOCK_AWS_LOG"
rc=0
MOCK_ALARM_MODE=missing CANARY_NOW=2026-10-01T12:00:00Z tick_alias_canaries || rc=$?
[ "$rc" -ne 0 ] || { echo "missing alarm must exit non-zero" >&2; exit 1; }
assert_no_update "missing alarm must not call update-alias"
if grep -q 'get-alias' "$MOCK_AWS_LOG"; then
  echo "missing alarm must fail before get-alias" >&2
  cat "$MOCK_AWS_LOG" >&2
  exit 1
fi
assert_no_issue "missing alarm must not open an issue"

# 2. Empty weight map: exit 0, no alias change, even if an alarm is ALARM.
python3 - "$TMP/alias.json" <<'PY'
import json, sys
p = sys.argv[1]
a = json.load(open(p))
a["RoutingConfig"] = {}
json.dump(a, open(p, "w"))
PY
: >"$MOCK_AWS_UPDATE"
: >"$MOCK_GH_LOG"
rc=0
MOCK_ALARM_MODE=alarm-quota CANARY_NOW=2026-10-01T12:00:00Z tick_alias_canaries || rc=$?
[ "$rc" -eq 0 ] || { echo "empty weight map must exit 0, got $rc" >&2; exit 1; }
assert_no_update "empty weight map must not call update-alias"
assert_no_issue "empty weight map must not open an issue"

# 3. Deleted FunctionVersion: non-zero, no alias change.
python3 - "$TMP/alias.json" <<'PY'
import json, sys
p = sys.argv[1]
a = json.load(open(p))
a["RoutingConfig"] = {"AdditionalVersionWeights": {"13": 0.05}}
json.dump(a, open(p, "w"))
PY
: >"$MOCK_AWS_UPDATE"
: >"$MOCK_GH_LOG"
rc=0
MOCK_ALARM_MODE=ok MOCK_MISSING_VERSION=12 CANARY_NOW=2026-10-01T12:00:00Z tick_alias_canaries || rc=$?
[ "$rc" -ne 0 ] || { echo "deleted FunctionVersion must exit non-zero" >&2; exit 1; }
assert_no_update "deleted FunctionVersion must not call update-alias"
assert_no_issue "deleted FunctionVersion must not open an issue"
unset MOCK_MISSING_VERSION

# 4. Valid canary + quota ALARM: FunctionVersion=old, clear weights,
# one issue, exit non-zero. Must not list published versions or set 0.95.
: >"$MOCK_AWS_UPDATE"
: >"$MOCK_GH_LOG"
: >"$MOCK_AWS_LOG"
: >"$MOCK_GH_CREATE"
: >"$MOCK_GH_BODY"
rc=0
MOCK_ALARM_MODE=alarm-quota CANARY_NOW=2026-10-01T12:00:00Z tick_alias_canaries || rc=$?
[ "$rc" -ne 0 ] || { echo "ALARM abort must exit non-zero" >&2; exit 1; }
grep -q 'function-version 12' "$MOCK_AWS_UPDATE" || {
  echo "abort must set FunctionVersion to 12:" >&2
  cat "$MOCK_AWS_UPDATE" >&2
  exit 1
}
if grep -q 'function-version 13' "$MOCK_AWS_UPDATE"; then
  echo "abort must not set FunctionVersion to the 0.05 key:" >&2
  cat "$MOCK_AWS_UPDATE" >&2
  exit 1
fi
grep -q 'AdditionalVersionWeights={}' "$MOCK_AWS_UPDATE" || {
  echo "abort must clear the weight map:" >&2
  cat "$MOCK_AWS_UPDATE" >&2
  exit 1
}
if grep -q '0.95' "$MOCK_AWS_UPDATE"; then
  echo "abort must not add a 0.95 weight key:" >&2
  cat "$MOCK_AWS_UPDATE" >&2
  exit 1
fi
if grep -q 'list-versions-by-function' "$MOCK_AWS_LOG"; then
  echo "abort must not select a predecessor from the published list" >&2
  exit 1
fi
grep -q 'issue create' "$MOCK_GH_LOG" || {
  echo "abort must open one GitHub issue:" >&2
  cat "$MOCK_GH_LOG" >&2
  exit 1
}
grep -q 'schema-canary-rollback SchemaFn 12 13' "$MOCK_GH_CREATE" || {
  echo "issue title must name function old new:" >&2
  cat "$MOCK_GH_CREATE" >&2
  exit 1
}
grep -q 'alarm: schema-mutation-gate-hourly-quota-prod' "$MOCK_GH_BODY" || {
  echo "issue body must name the firing alarm:" >&2
  cat "$MOCK_GH_BODY" >&2
  exit 1
}
grep -q 'function: SchemaFn' "$MOCK_GH_BODY" || { echo "missing function field" >&2; exit 1; }
grep -q 'old: 12' "$MOCK_GH_BODY" || { echo "missing old field" >&2; exit 1; }
grep -q 'new: 13' "$MOCK_GH_BODY" || { echo "missing new field" >&2; exit 1; }
assert_no_kanban

# Internal-error ALARM also aborts.
: >"$MOCK_AWS_UPDATE"
: >"$MOCK_GH_LOG"
rc=0
MOCK_ALARM_MODE=alarm-error CANARY_NOW=2026-10-01T12:00:00Z tick_alias_canaries || rc=$?
[ "$rc" -ne 0 ] || { echo "internal-error ALARM must abort" >&2; exit 1; }
grep -q 'function-version 12' "$MOCK_AWS_UPDATE" || {
  echo "internal-error abort must target version 12" >&2
  exit 1
}

# OK during soak does not roll back.
: >"$MOCK_AWS_UPDATE"
: >"$MOCK_GH_LOG"
rc=0
MOCK_ALARM_MODE=ok CANARY_NOW=2026-10-01T12:00:00Z tick_alias_canaries || rc=$?
[ "$rc" -eq 0 ] || { echo "OK during soak must exit 0, got $rc" >&2; exit 1; }
assert_no_update "OK must not call update-alias"
assert_no_issue "OK must not open an issue"

# INSUFFICIENT_DATA during soak does not roll back.
: >"$MOCK_AWS_UPDATE"
: >"$MOCK_GH_LOG"
rc=0
MOCK_ALARM_MODE=insufficient CANARY_NOW=2026-10-01T12:00:00Z tick_alias_canaries || rc=$?
[ "$rc" -eq 0 ] || { echo "INSUFFICIENT_DATA must exit 0, got $rc" >&2; exit 1; }
assert_no_update "INSUFFICIENT_DATA must not call update-alias"
assert_no_issue "INSUFFICIENT_DATA must not open an issue"

# Weight 0.10 is not the canary shape: fail, move no alias, open no issue.
python3 - "$TMP/alias.json" <<'PY'
import json, sys
p = sys.argv[1]
a = json.load(open(p))
a["RoutingConfig"] = {"AdditionalVersionWeights": {"13": 0.10}}
json.dump(a, open(p, "w"))
PY
: >"$MOCK_AWS_UPDATE"
: >"$MOCK_GH_LOG"
rc=0
MOCK_ALARM_MODE=alarm-quota CANARY_NOW=2026-10-02T01:00:00Z tick_alias_canaries || rc=$?
[ "$rc" -ne 0 ] || { echo "non-0.05 weight must exit non-zero" >&2; exit 1; }
assert_no_update "non-0.05 weight must not call update-alias"
assert_no_issue "non-0.05 weight must not open an issue"

# Two-key weight map is also a bad shape.
python3 - "$TMP/alias.json" <<'PY'
import json, sys
p = sys.argv[1]
a = json.load(open(p))
a["RoutingConfig"] = {"AdditionalVersionWeights": {"13": 0.05, "11": 0.95}}
json.dump(a, open(p, "w"))
PY
: >"$MOCK_AWS_UPDATE"
: >"$MOCK_GH_LOG"
rc=0
MOCK_ALARM_MODE=alarm-quota CANARY_NOW=2026-10-01T12:00:00Z tick_alias_canaries || rc=$?
[ "$rc" -ne 0 ] || { echo "two-key weight map must exit non-zero" >&2; exit 1; }
assert_no_update "two-key weight map must not call update-alias"
assert_no_issue "two-key weight map must not open an issue"

# 5. Second tick after abort (empty map) exits 0 and opens no second issue.
python3 - "$TMP/alias.json" <<'PY'
import json, sys
p = sys.argv[1]
a = json.load(open(p))
a["RoutingConfig"] = {}
json.dump(a, open(p, "w"))
PY
: >"$MOCK_AWS_UPDATE"
: >"$MOCK_GH_LOG"
rc=0
MOCK_ALARM_MODE=alarm-quota CANARY_NOW=2026-10-01T12:00:00Z tick_alias_canaries || rc=$?
[ "$rc" -eq 0 ] || { echo "second tick after abort must exit 0, got $rc" >&2; exit 1; }
assert_no_update "second tick after abort must not call update-alias"
assert_no_issue "second tick after abort must not open another issue"

# Issue API failure still exits non-zero after a successful abort and writes
# the four fields to the job summary.
python3 - "$TMP/alias.json" <<'PY'
import json, sys
p = sys.argv[1]
a = json.load(open(p))
a["RoutingConfig"] = {"AdditionalVersionWeights": {"13": 0.05}}
json.dump(a, open(p, "w"))
PY
: >"$MOCK_AWS_UPDATE"
: >"$MOCK_GH_LOG"
: >"$GITHUB_STEP_SUMMARY"
rc=0
MOCK_GH_FAIL=1 MOCK_ALARM_MODE=alarm-quota CANARY_NOW=2026-10-01T12:00:00Z tick_alias_canaries || rc=$?
[ "$rc" -ne 0 ] || { echo "issue failure after abort must still exit non-zero" >&2; exit 1; }
grep -q 'function-version 12' "$MOCK_AWS_UPDATE" || {
  echo "issue failure must not skip the alias abort" >&2
  exit 1
}
grep -q 'alarm: schema-mutation-gate-hourly-quota-prod' "$GITHUB_STEP_SUMMARY" || {
  echo "issue fallback must write alarm to the job summary:" >&2
  cat "$GITHUB_STEP_SUMMARY" >&2
  exit 1
}
grep -q 'function: SchemaFn' "$GITHUB_STEP_SUMMARY" || {
  echo "issue fallback must write function to the job summary" >&2
  exit 1
}
grep -q 'old: 12' "$GITHUB_STEP_SUMMARY" || {
  echo "issue fallback must write old to the job summary" >&2
  exit 1
}
grep -q 'new: 13' "$GITHUB_STEP_SUMMARY" || {
  echo "issue fallback must write new to the job summary" >&2
  exit 1
}
assert_no_kanban

echo "ok canary-alarm-loop"
