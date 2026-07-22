#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

export SCHEMA_DEPLOY_TELEMETRY_FILE="$tmpdir/telemetry/schema-deploy-telemetry.jsonl"

# shellcheck source=scripts/deploy/telemetry.sh
source "$ROOT/scripts/deploy/telemetry.sh"

started="$(schema_telemetry_stage_start dry_run)"
schema_telemetry_stage_end dry_run "$started"
"$ROOT/scripts/deploy/dependency-budget.sh" >/tmp/schema-infra-dependency-budget-test.out

test -s "$SCHEMA_DEPLOY_TELEMETRY_FILE"
grep -q '"event":"stage_start"' "$SCHEMA_DEPLOY_TELEMETRY_FILE"
grep -q '"event":"stage_end"' "$SCHEMA_DEPLOY_TELEMETRY_FILE"
grep -q '"event":"dependency_budget"' "$SCHEMA_DEPLOY_TELEMETRY_FILE"
grep -q 'SCHEMA_DEPLOY_TELEMETRY event=dependency_budget' /tmp/schema-infra-dependency-budget-test.out
