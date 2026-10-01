#!/usr/bin/env bash
# The alias ticker soaks a 5% live weight for 24h, promotes when due, and
# rolls back on ALARM. A 10% weight is left alone (another writer).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/scripts/deploy/canary-lib.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export LASTGIT_DEPLOY_LOG_DIR="$TMP/state"
export CANARY_ALIAS_FN="SchemaFn"
export CANARY_ALIAS_REGION="us-east-1"
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
  printf '%s\n' "${MOCK_ALARM_STATE:-OK}"
  exit 0
fi
if [ "${1:-}" = "lambda" ] && [ "${2:-}" = "get-function" ]; then
  exit 0
fi
if [ "${1:-}" = "lambda" ] && [ "${2:-}" = "update-alias" ]; then
  printf '%s\n' "$*" >"${MOCK_AWS_UPDATE}"
  exit 0
fi
exit 0
EOF
chmod +x "$TMP/bin/aws"
export MOCK_AWS_LOG="$TMP/aws.log"
export MOCK_AWS_UPDATE="$TMP/update"
: >"$MOCK_AWS_LOG"
: >"$MOCK_AWS_UPDATE"

# shellcheck source=/dev/null
source "$LIB"

plan="$(CANARY_NOW=2026-10-01T12:00:00Z canary_alias_plan SchemaFn us-east-1)"
case "$plan" in
  soaking$'\t'12$'\t'13$'\t'*) ;;
  *) echo "expected soaking at 12h, got: $plan" >&2; exit 1 ;;
esac

plan="$(CANARY_NOW=2026-10-02T00:00:00Z canary_alias_plan SchemaFn us-east-1)"
case "$plan" in
  due$'\t'12$'\t'13$'\t'*) ;;
  *) echo "expected due at 24h, got: $plan" >&2; exit 1 ;;
esac

python3 - "$TMP/alias.json" <<'PY'
import json, sys
p = sys.argv[1]
a = json.load(open(p))
a["RoutingConfig"]["AdditionalVersionWeights"] = {"13": 0.10}
json.dump(a, open(p, "w"))
PY
plan="$(CANARY_NOW=2026-10-02T00:00:00Z canary_alias_plan SchemaFn us-east-1)"
[ "$plan" = "idle" ] || { echo "10% weight must be idle, got: $plan" >&2; exit 1; }

python3 - "$TMP/alias.json" <<'PY'
import json, sys
p = sys.argv[1]
a = json.load(open(p))
a["RoutingConfig"] = {}
json.dump(a, open(p, "w"))
PY
plan="$(canary_alias_plan SchemaFn us-east-1)"
[ "$plan" = "idle" ] || { echo "empty routing must be idle, got: $plan" >&2; exit 1; }

# Restore the 5% canary and roll it back on ALARM during the soak.
python3 - "$TMP/alias.json" <<'PY'
import json, sys
p = sys.argv[1]
a = json.load(open(p))
a["RoutingConfig"] = {"AdditionalVersionWeights": {"13": 0.05}}
json.dump(a, open(p, "w"))
PY
: >"$MOCK_AWS_UPDATE"
rc=0
MOCK_ALARM_STATE=ALARM CANARY_NOW=2026-10-01T12:00:00Z tick_alias_canaries || rc=$?
[ "$rc" -eq 1 ] || { echo "ALARM during soak must return 1, got $rc" >&2; exit 1; }
grep -q 'function-version 12' "$MOCK_AWS_UPDATE" || {
  echo "rollback must target the primary version 12:" >&2
  cat "$MOCK_AWS_UPDATE" >&2
  exit 1
}

# Due and healthy: promote the canary version.
: >"$MOCK_AWS_UPDATE"
rc=0
MOCK_ALARM_STATE=OK CANARY_NOW=2026-10-02T01:00:00Z tick_alias_canaries || rc=$?
[ "$rc" -eq 0 ] || { echo "due + OK must return 0, got $rc" >&2; exit 1; }
grep -q 'function-version 13' "$MOCK_AWS_UPDATE" || {
  echo "promote must target version 13:" >&2
  cat "$MOCK_AWS_UPDATE" >&2
  exit 1
}
echo "ok canary-alias-tick"
