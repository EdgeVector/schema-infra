#!/usr/bin/env bash
# Promote or roll back the schema-infra prod canary from the live alias.
# canary-ticker.yml runs this every 15 minutes. deploy-pipeline.sh runs it
# as the pre-prod tick.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
# shellcheck source=scripts/deploy/canary-lib.sh
source "$ROOT/scripts/deploy/canary-lib.sh"

tick_alias_canaries
exit $?
