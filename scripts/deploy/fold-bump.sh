#!/usr/bin/env bash
# Open one PR that moves the `fold` pin to lastdb main, but only when a
# Schema Service Lambda input changed (scripts/deploy/fold-lambda-inputs.txt).
#
# .github/workflows/auto-deploy-on-fold.yml calls this on a lastdb
# repository_dispatch, on a 30-minute schedule, and on a manual dispatch.
# The PR has one commit that changes only the `fold` gitlink. Auto-merge
# (squash) merges it after the required checks. The push to main then runs
# deploy.yml: DEV deploy, DEV smoke, then the PROD canary rules.
#
# It stops with one summary line when:
#   - a bump PR (branch auto/fold-bump-*) is still open (it re-arms that
#     PR's auto-merge when the PR lost it);
#   - the pin already is lastdb main;
#   - no Lambda input changed between the pin and lastdb main;
#   - a person closed the bump PR for this lastdb revision.
# It fails when lastdb main does not contain the pin. A person must look.
#
# Env:
#   GH_TOKEN           pushes the branch and opens the PR. Use the org GH_PAT:
#                      a PR that GITHUB_TOKEN opens does not start the checks.
#   GITHUB_REPOSITORY  this repo (default EdgeVector/schema-infra)
#   FOLD_REPO          the pinned repo (default EdgeVector/lastdb)
#   DISPATCH_SHA       optional lastdb sha from the repository_dispatch payload
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT="$(pwd)"

REPO="${GITHUB_REPOSITORY:-EdgeVector/schema-infra}"
FOLD_REPO="${FOLD_REPO:-EdgeVector/lastdb}"
INPUTS_FILE="$ROOT/scripts/deploy/fold-lambda-inputs.txt"
BRANCH_PREFIX="auto/fold-bump-"
: "${GH_TOKEN:?GH_TOKEN is required}"

say() {
    printf '%s\n' "$*"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        printf '%s\n' "$*" >> "$GITHUB_STEP_SUMMARY"
    fi
}

work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/fold-bump.XXXXXX")"
trap 'rm -rf "$work"' EXIT

if [ -n "${DISPATCH_SHA:-}" ]; then
    echo "repository_dispatch from lastdb ${DISPATCH_SHA}"
fi

# 1. One bump at a time. An open bump PR that lost its auto-merge gets it back.
gh pr list --repo "$REPO" --state open --limit 100 \
    --json number,headRefName,url,autoMergeRequest > "$work/open.json"
open_url="$(jq -r --arg p "$BRANCH_PREFIX" \
    '[.[] | select(.headRefName | startswith($p))] | sort_by(.number) | .[0].url // ""' \
    "$work/open.json")"
if [ -n "$open_url" ]; then
    armed="$(jq -r --arg u "$open_url" \
        '.[] | select(.url == $u) | (.autoMergeRequest != null)' "$work/open.json")"
    if [ "$armed" != true ]; then
        gh pr merge "$open_url" --repo "$REPO" --auto --squash
    fi
    say "fold bump: bump PR $open_url is open. The next bump starts after it merges."
    exit 0
fi

# 2. Read the pin and lastdb main. The clone holds commits and trees only.
pin="$(git -C "$ROOT" rev-parse HEAD:fold)"
basic="$(printf 'x-access-token:%s' "$GH_TOKEN" | base64 | tr -d '\n')"
if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "::add-mask::$basic"
fi
auth="http.extraheader=AUTHORIZATION: basic $basic"
git -c "$auth" -C "$work" clone --quiet --bare --filter=blob:none --depth=1 \
    --no-tags --single-branch --branch main \
    "https://github.com/${FOLD_REPO}.git" fold.git
latest="$(git -C "$work/fold.git" rev-parse refs/heads/main)"
echo "pin:         $pin"
echo "lastdb main: $latest"
if [ "$pin" = "$latest" ]; then
    say "fold bump: the pin is lastdb main ${latest:0:12}. No bump."
    exit 0
fi

# 3. lastdb main must contain the pin. Never move the pin to another line.
status="$(gh api "repos/${FOLD_REPO}/compare/${pin}...${latest}?per_page=1" --jq .status)"
if [ "$status" != ahead ]; then
    say "fold bump: FAIL. lastdb main ${latest:0:12} does not contain the pin ${pin:0:12} (compare status: ${status}). A person must check the pin."
    exit 1
fi

# 4. Compare only the Lambda inputs between the pin and lastdb main.
git -c "$auth" -C "$work/fold.git" fetch --quiet --no-tags --depth=1 origin "$pin"
git -c "$auth" -C "$work/fold.git" diff --no-renames --name-only "$pin" "$latest" -- \
    > "$work/changed.txt"
inputs=()
while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    inputs+=("$line")
done < "$INPUTS_FILE"
[ "${#inputs[@]}" -gt 0 ] || { echo "FAIL: $INPUTS_FILE lists no input" >&2; exit 1; }
: > "$work/relevant.txt"
while IFS= read -r path; do
    [ -n "$path" ] || continue
    case "$path" in *.md) continue ;; esac
    for input in "${inputs[@]}"; do
        case "$input" in
            */) case "$path" in "$input"*) echo "$path" >> "$work/relevant.txt"; break ;; esac ;;
            *) if [ "$path" = "$input" ]; then echo "$path" >> "$work/relevant.txt"; break; fi ;;
        esac
    done
done < "$work/changed.txt"
total="$(wc -l < "$work/changed.txt" | tr -d ' ')"
count="$(wc -l < "$work/relevant.txt" | tr -d ' ')"
compare_url="https://github.com/${FOLD_REPO}/compare/${pin}...${latest}"
if [ "$count" = 0 ]; then
    say "fold bump: ${total} files changed between the pin ${pin:0:12} and lastdb main ${latest:0:12}. None is a Schema Service input. No bump."
    exit 0
fi

# 5. A person closed the bump PR for this revision: wait for a newer lastdb main.
branch="${BRANCH_PREFIX}${latest:0:12}"
closed="$(gh pr list --repo "$REPO" --state closed --head "$branch" \
    --json number,mergedAt --jq '[.[] | select(.mergedAt == null)] | length')"
if [ "$closed" != 0 ]; then
    say "fold bump: a person closed the bump PR for lastdb ${latest:0:12}. The next lastdb change starts a new bump."
    exit 0
fi
if git -C "$ROOT" ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
    branch="${branch}-r${GITHUB_RUN_ID:-$(date -u +%s)}"
fi

# 6. Commit only the gitlink. Push a new branch. Never force.
git -C "$ROOT" config user.name "fold-autobump[bot]"
git -C "$ROOT" config user.email "fold-autobump@users.noreply.github.com"
git -C "$ROOT" switch --quiet -c "$branch"
git -C "$ROOT" update-index --cacheinfo "160000,${latest},fold"
staged="$(git -C "$ROOT" diff --cached --name-only)"
if [ "$staged" != fold ]; then
    echo "FAIL: the bump commit must change only the fold gitlink; staged: $staged" >&2
    exit 1
fi
title="Bump fold to ${latest:0:12}: Schema Service inputs changed"
{
    printf '%s\n\n' "$title"
    printf 'Move the fold pin from %s to lastdb main %s.\n' "${pin:0:12}" "${latest:0:12}"
    printf '%s of %s changed files in this range are Schema Service inputs.\n\n' "$count" "$total"
    printf 'Compare: %s\n' "$compare_url"
    printf 'Opened by .github/workflows/auto-deploy-on-fold.yml.\n'
} > "$work/message.txt"
git -C "$ROOT" commit --quiet -F "$work/message.txt"
git -C "$ROOT" push --quiet origin "HEAD:refs/heads/${branch}"

# The backticks below are Markdown code spans in the PR body.
# shellcheck disable=SC2016
{
    printf 'Move the `fold` pin from `%s` to lastdb main `%s`.\n\n' "${pin:0:12}" "${latest:0:12}"
    printf '%s of %s changed files in [this range](%s) are Schema Service inputs. Examples:\n\n' \
        "$count" "$total" "$compare_url"
    head -n 10 "$work/relevant.txt" | sed 's/.*/- `&`/'
    printf '\nAfter the merge, `deploy.yml` deploys DEV and runs the DEV smoke check. '
    printf 'PROD follows the canary rules in `.github/workflows/README.md`.\n\n'
    printf 'Opened by `.github/workflows/auto-deploy-on-fold.yml`.\n'
} > "$work/body.md"
url="$(gh pr create --repo "$REPO" --base main --head "$branch" \
    --title "$title" --body-file "$work/body.md")"
armed=0
for attempt in 1 2 3; do
    if gh pr merge "$url" --repo "$REPO" --auto --squash; then
        armed=1
        break
    fi
    sleep $((attempt * 10))
done
if [ "$armed" != 1 ]; then
    say "fold bump: opened $url but could not arm auto-merge. The next run tries again."
    exit 1
fi
say "fold bump: opened $url with auto-merge (squash). ${count} Schema Service input files changed."
