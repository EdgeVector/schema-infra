#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
PROBE="$ROOT/scripts/deploy/prove-mutation-gate.sh"

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
if bash "$PROBE" --max-quota-attempts 131 >/dev/null 2>&1; then
  echo "FAIL: excessive quota attempts accepted" >&2
  exit 1
fi

echo "ok mutation-gate proof guards"
