#!/usr/bin/env bash
# Live-surface proof for schema canary abort + GitHub-issue hop.
# A pass means the ticker:
#   - leaves the alias in place on missing alarm, empty weights, or deleted FunctionVersion
#   - aborts a valid 5% canary to FunctionVersion and an empty weight map
#   - opens one GitHub issue (or the test double) and exits non-zero
#   - never selects a predecessor from the published version list
#   - never calls kanban
#   - a second tick with an empty map after abort exits 0 and opens no second issue
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
bash "$ROOT/scripts/deploy/test-canary-rollback-issue.sh"
echo "ok canary-alarm-loop"
