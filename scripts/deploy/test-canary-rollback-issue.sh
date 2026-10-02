#!/usr/bin/env bash
# The abort tick opens one GitHub issue labeled schema-canary-rollback and
# never calls kanban. A missing alarm or empty weight map opens no issue.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/scripts/deploy/canary-lib.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/canary-issue.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export LASTGIT_DEPLOY_LOG_DIR="$TMP/state"
export CANARY_ALIAS_FN="SchemaFn"
export CANARY_ALIAS_REGION="us-east-1"
export SCHEMA_CANARY_OPEN_ISSUE=1
export SCHEMA_CANARY_ISSUE_REPO="EdgeVector/schema-infra"
export SCHEMA_CANARY_ALERT_NOTICE=0
export PATH="$TMP/bin:$PATH"
mkdir -p "$TMP/bin" "$TMP/state"

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
    alarm:*) printf '%s\n' ALARM ;;
    missing:schema-mutation-gate-hourly-quota-prod) printf '%s\n' None ;;
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
  printf '%s\n' "$*" >"${MOCK_AWS_UPDATE}"
  exit 0
fi
if [ "${1:-}" = "lambda" ] && [ "${2:-}" = "list-versions-by-function" ]; then
  echo "list-versions-by-function must not run" >>"${MOCK_AWS_LOG}"
  exit 1
fi
exit 0
EOF
chmod +x "$TMP/bin/aws"

cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >>"${MOCK_GH_LOG}"
if [ "${1:-}" = "label" ]; then
  exit 0
fi
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "create" ]; then
  if [ "${MOCK_GH_FAIL:-0}" = "1" ]; then
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
  printf '%s\n' "https://github.com/EdgeVector/schema-infra/issues/9"
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

# shellcheck source=/dev/null
source "$LIB"

# ALARM during soak: roll back, open one issue, exit 1, never call kanban.
: >"$MOCK_AWS_UPDATE"
: >"$MOCK_GH_CREATE"
: >"$MOCK_GH_BODY"
rc=0
MOCK_ALARM_MODE=alarm CANARY_NOW=2026-10-01T12:00:00Z tick_alias_canaries || rc=$?
[ "$rc" -eq 1 ] || { echo "ALARM abort must return 1, got $rc" >&2; exit 1; }
grep -q 'function-version 12' "$MOCK_AWS_UPDATE" || {
  echo "rollback must target FunctionVersion 12:" >&2
  cat "$MOCK_AWS_UPDATE" >&2
  exit 1
}
grep -q 'AdditionalVersionWeights={}' "$MOCK_AWS_UPDATE" || {
  echo "rollback must clear the weight map:" >&2
  cat "$MOCK_AWS_UPDATE" >&2
  exit 1
}
grep -q 'schema-canary-rollback' "$MOCK_GH_CREATE" || {
  echo "abort must open an issue labeled schema-canary-rollback:" >&2
  cat "$MOCK_GH_CREATE" >&2
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
if [ -s "$MOCK_KANBAN_LOG" ]; then
  echo "ticker must not call kanban:" >&2
  cat "$MOCK_KANBAN_LOG" >&2
  exit 1
fi
if grep -q 'list-versions-by-function' "$MOCK_AWS_LOG"; then
  echo "abort must not pick a predecessor from published versions" >&2
  exit 1
fi

# Second tick after abort: empty weight map, exit 0, no second issue.
python3 - "$TMP/alias.json" <<'PY'
import json, sys
p = sys.argv[1]
a = json.load(open(p))
a["FunctionVersion"] = "12"
a["RoutingConfig"] = {}
json.dump(a, open(p, "w"))
PY
: >"$MOCK_AWS_UPDATE"
: >"$MOCK_GH_LOG"
rc=0
MOCK_ALARM_MODE=alarm CANARY_NOW=2026-10-01T12:00:00Z tick_alias_canaries || rc=$?
[ "$rc" -eq 0 ] || { echo "post-abort empty map must return 0, got $rc" >&2; exit 1; }
if [ -s "$MOCK_AWS_UPDATE" ]; then
  echo "post-abort empty map must not call update-alias" >&2
  cat "$MOCK_AWS_UPDATE" >&2
  exit 1
fi
if grep -q 'issue create' "$MOCK_GH_LOG"; then
  echo "post-abort empty map must not open a second issue" >&2
  cat "$MOCK_GH_LOG" >&2
  exit 1
fi

# Restore the 5% canary for the remaining cases.
python3 - "$TMP/alias.json" <<'PY'
import json, sys
p = sys.argv[1]
a = json.load(open(p))
a["FunctionVersion"] = "12"
a["RoutingConfig"] = {"AdditionalVersionWeights": {"13": 0.05}}
json.dump(a, open(p, "w"))
PY

# Missing configured alarm: no alias change, no issue.
: >"$MOCK_AWS_UPDATE"
: >"$MOCK_GH_CREATE"
: >"$MOCK_GH_LOG"
rc=0
MOCK_ALARM_MODE=missing CANARY_NOW=2026-10-01T12:00:00Z tick_alias_canaries || rc=$?
[ "$rc" -eq 1 ] || { echo "missing alarm must return 1, got $rc" >&2; exit 1; }
if [ -s "$MOCK_AWS_UPDATE" ]; then
  echo "missing alarm must not call update-alias:" >&2
  cat "$MOCK_AWS_UPDATE" >&2
  exit 1
fi
if grep -q 'issue create' "$MOCK_GH_LOG"; then
  echo "missing alarm must not open an issue" >&2
  cat "$MOCK_GH_LOG" >&2
  exit 1
fi

# Empty weight map: exit 0, no issue, no alias change.
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
MOCK_ALARM_MODE=alarm CANARY_NOW=2026-10-01T12:00:00Z tick_alias_canaries || rc=$?
[ "$rc" -eq 0 ] || { echo "empty weight map must return 0, got $rc" >&2; exit 1; }
if [ -s "$MOCK_AWS_UPDATE" ]; then
  echo "empty weight map must not call update-alias" >&2
  exit 1
fi
if grep -q 'issue create' "$MOCK_GH_LOG"; then
  echo "empty weight map must not open an issue" >&2
  exit 1
fi

# Restore canary. Deleted FunctionVersion: no alias change, no issue.
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
MOCK_ALARM_MODE=alarm MOCK_MISSING_VERSION=12 CANARY_NOW=2026-10-01T12:00:00Z \
  tick_alias_canaries || rc=$?
[ "$rc" -eq 1 ] || { echo "deleted FunctionVersion must return 1, got $rc" >&2; exit 1; }
if [ -s "$MOCK_AWS_UPDATE" ]; then
  echo "deleted FunctionVersion must not call update-alias" >&2
  cat "$MOCK_AWS_UPDATE" >&2
  exit 1
fi
if grep -q 'issue create' "$MOCK_GH_LOG"; then
  echo "deleted FunctionVersion must not open an issue" >&2
  exit 1
fi

# gh failure after a successful abort still writes the four fields to the
# job summary and still exits non-zero.
export GITHUB_STEP_SUMMARY="$TMP/summary.md"
: >"$GITHUB_STEP_SUMMARY"
: >"$MOCK_AWS_UPDATE"
unset MOCK_MISSING_VERSION
rc=0
MOCK_GH_FAIL=1 MOCK_ALARM_MODE=alarm CANARY_NOW=2026-10-01T12:00:00Z \
  tick_alias_canaries || rc=$?
[ "$rc" -eq 1 ] || { echo "failed issue create must still return 1, got $rc" >&2; exit 1; }
grep -q 'function-version 12' "$MOCK_AWS_UPDATE" || {
  echo "alias abort must happen before the issue call" >&2
  exit 1
}
grep -q 'alarm: schema-mutation-gate-hourly-quota-prod' "$GITHUB_STEP_SUMMARY" || {
  echo "failed issue create must write fields to GITHUB_STEP_SUMMARY:" >&2
  cat "$GITHUB_STEP_SUMMARY" >&2
  exit 1
}
grep -q 'function: SchemaFn' "$GITHUB_STEP_SUMMARY" || { echo "summary missing function" >&2; exit 1; }
grep -q 'old: 12' "$GITHUB_STEP_SUMMARY" || { echo "summary missing old" >&2; exit 1; }
grep -q 'new: 13' "$GITHUB_STEP_SUMMARY" || { echo "summary missing new" >&2; exit 1; }

echo "ok canary-rollback-issue"
