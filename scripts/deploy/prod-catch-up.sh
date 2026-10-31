#!/usr/bin/env bash
# PROD catch-up. canary-ticker.yml runs this after each successful tick.
#
# A deploy run defers PROD while a canary soaks (.lastgit/deploy-pipeline.sh).
# A run can also skip PROD when a newer main tip supersedes it. When no canary
# is on the live alias and PROD is behind main, this script starts one
# deploy.yml run with target=prod. That run keeps the normal order: DEV
# deploy, DEV smoke, PROD 5% pin, 24-hour soak, promotion by the ticker.
#
# It starts no run, and says why, when one of these is true:
#   - canonical-vocabulary/phase is not prod;
#   - the live alias still has a weighted canary (it soaks, or it waits for
#     the tick);
#   - an open issue labeled schema-canary-rollback exists (a person reviews
#     the rollback first);
#   - a deploy.yml run is queued or running;
#   - the newest finished deploy.yml run on main did not succeed (no retry
#     loop; a new main push or a person starts the next run);
#   - the classifier finds no deploy impact between PROD's last deployed oid
#     and main.
#
# Env: GH_TOKEN (actions: write to start the run and read artifacts; issues:
# read), GITHUB_REPOSITORY, AWS credentials for the PROD role (alias read
# only). The checkout must have the main history (fetch-depth: 0).
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT="$(pwd)"
# shellcheck source=scripts/deploy/canary-lib.sh
source "$ROOT/scripts/deploy/canary-lib.sh"

REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GH_TOKEN:?GH_TOKEN is required}"

say() {
    printf 'prod catch-up: %s\n' "$*"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        printf 'prod catch-up: %s\n' "$*" >> "$GITHUB_STEP_SUMMARY"
    fi
}

work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/prod-catch-up.XXXXXX")"
trap 'rm -rf "$work"' EXIT

phase="$(canonical_vocabulary_phase)"
if [ "$phase" != prod ]; then
    say "none. Phase $phase holds PROD."
    exit 0
fi

fn="$(schema_fn_name prod us-east-1 || true)"
if [ -z "${fn:-}" ] || [ "$fn" = None ]; then
    say "none. No PROD function."
    exit 0
fi
plan="$(canary_alias_plan "$fn" us-east-1)"
action="${plan%%$'\t'*}"
if [ "$action" != idle ]; then
    say "none. The live alias canary is $action."
    exit 0
fi

rollbacks="$(gh issue list --repo "$REPO" --label schema-canary-rollback --state open \
    --json number --jq length)"
if [ "$rollbacks" != 0 ]; then
    say "none. $rollbacks open schema-canary-rollback issue(s) wait for a person."
    exit 0
fi

gh run list --repo "$REPO" --workflow deploy.yml --branch main --limit 20 \
    --json databaseId,status,conclusion,event,headSha > "$work/runs.json"
active="$(jq '[.[] | select(.status != "completed")] | length' "$work/runs.json")"
if [ "$active" != 0 ]; then
    say "none. A deploy run is queued or running."
    exit 0
fi
newest="$(jq -r '[.[] | select(.conclusion != "skipped" and .conclusion != "cancelled")]
    | max_by(.databaseId) // {} | "\(.conclusion // "none")\t\(.databaseId // "-")"' "$work/runs.json")"
newest_conclusion="${newest%%$'\t'*}"
newest_id="${newest#*$'\t'}"
if [ "$newest_conclusion" != success ]; then
    say "none. The newest finished deploy run ($newest_id) is $newest_conclusion. A new main push or a person starts the next run."
    exit 0
fi

LASTGIT_DEPLOY_LOG_DIR="$work/prod-state" DEPLOY_ENV=prod \
    bash "$ROOT/scripts/deploy/restore-last-oid.sh"
base=""
if [ -s "$work/prod-state/last-deployed-oid" ]; then
    base="$(head -1 "$work/prod-state/last-deployed-oid" | tr -d '[:space:]')"
fi
head_oid="$(git -C "$ROOT" rev-parse HEAD)"
if [ -z "$base" ]; then
    kind=infrastructure
    reason="no PROD last-deployed oid"
else
    classified="$(bash "$ROOT/scripts/deploy/classify-change.sh" "$base" "$head_oid" "$ROOT")"
    kind="${classified%%$'\t'*}"
    reason="${classified#*$'\t'}"
fi
if [ "$kind" = no-impact ]; then
    say "none. PROD is current with main ${head_oid:0:12} ($reason)."
    exit 0
fi

gh workflow run deploy.yml --repo "$REPO" --ref main \
    -f target=prod -f confirm_prod=deploy-prod -f force_kind=auto
say "started deploy.yml target=prod on main ${head_oid:0:12}. PROD base ${base:-none}; $kind: $reason."
