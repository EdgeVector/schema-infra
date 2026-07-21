#!/usr/bin/env bash
# Unit test: the schema canary has a required default alarm set and fails
# closed when an alarm is ALARM, missing, or unreadable.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export LASTGIT_DEPLOY_LOG_DIR="$TMP/state"
export PATH="$TMP/bin:$PATH"
mkdir -p "$TMP/bin"

cat >"$TMP/bin/aws" <<'AWS'
#!/usr/bin/env bash
set -euo pipefail
name=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--alarm-names" ]; then name="${2:-}"; break; fi
  shift
done
case "${MOCK_ALARM_MODE:-ok}:$name" in
  alarm:schema-mutation-gate-internal-error-prod) echo ALARM ;;
  missing:schema-mutation-gate-hourly-quota-prod) echo None ;;
  *) echo OK ;;
esac
AWS
chmod +x "$TMP/bin/aws"

# shellcheck source=/dev/null
source "$ROOT/scripts/deploy/canary-lib.sh"
unset SCHEMA_CANARY_ALARM_NAMES || true

MOCK_ALARM_MODE=ok canary_alarms_ok us-east-1
if MOCK_ALARM_MODE=alarm canary_alarms_ok us-east-1; then
  echo "expected ALARM to block promotion" >&2
  exit 1
fi
if MOCK_ALARM_MODE=missing canary_alarms_ok us-east-1; then
  echo "expected a missing required alarm to block promotion" >&2
  exit 1
fi

export SCHEMA_CANARY_ALARM_NAMES="custom-schema-alarm"
MOCK_ALARM_MODE=ok canary_alarms_ok us-east-1
echo "ok canary-alarm-gate $(basename "$ROOT")"
