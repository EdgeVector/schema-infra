#!/usr/bin/env bash
# File one kanban card per open GitHub issue labeled schema-canary-rollback.
#
# The GitHub-hosted ticker cannot open folddb.sock and must not call kanban.
# This script runs on a host that can reach the LastDB socket. It is the only
# writer of the rollback card.
#
# Slug: schema-canary-rollback-<function>-v<old>-v<new>-<issue>
# If that slug exists, do not add another card. After a successful add,
# comment the slug on the issue. No North Star.
set -euo pipefail

SCHEMA_CANARY_ISSUE_REPO="${SCHEMA_CANARY_ISSUE_REPO:-EdgeVector/schema-infra}"
SCHEMA_CANARY_CARD_REPO="${SCHEMA_CANARY_CARD_REPO:-EdgeVector/schema-infra}"
KANBAN_BIN="${KANBAN_BIN:-kanban}"
GH_BIN="${CANARY_GH:-gh}"

canary_card_log() {
  printf '[canary-rollback-card] %s\n' "$*" >&2
}

canary_rollback_slug_part() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed -e 's/^-//' -e 's/-$//'
}

canary_rollback_slug() {
  local fn="$1" old="$2" new="$3" issue="$4"
  printf 'schema-canary-rollback-%s-v%s-v%s-%s\n' \
    "$(canary_rollback_slug_part "$fn")" \
    "$(canary_rollback_slug_part "$old")" \
    "$(canary_rollback_slug_part "$new")" \
    "$(canary_rollback_slug_part "$issue")"
}

canary_rollback_card_body() {
  local alarm="$1" fn="$2" old="$3" new="$4" repo="$5"
  cat <<EOF
Repo: ${repo}
Base: main
Kind: pr

alarm: ${alarm}
function: ${fn}
old: ${old}
new: ${new}

## GOAL
Abort the schema live canary after the named alarm.
Keep traffic on the old version. Clear the live weight map.

## END STATE
Live alias FunctionVersion is the old version.
AdditionalVersionWeights is empty.
The card names the alarm, the function, the old version, and the new version.
EOF
}

canary_card_exists() {
  local slug="$1"
  "$KANBAN_BIN" show "$slug" >/dev/null 2>/dev/null
}

parse_open_rollback_issues() {
  local json_file="$1"
  python3 - "$json_file" <<'PY'
import json, sys
path = sys.argv[1]
raw = open(path, "r", encoding="utf-8").read().strip()
if not raw:
    raise SystemExit(0)
try:
    issues = json.loads(raw)
except Exception:
    raise SystemExit(0)
if not isinstance(issues, list):
    raise SystemExit(0)
wanted = ("alarm", "function", "old", "new")
for issue in issues:
    body = issue.get("body") or ""
    fields = {}
    for line in body.splitlines():
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        key = key.strip().lower()
        value = value.strip()
        if key in wanted and value:
            fields[key] = value
    if all(k in fields for k in wanted):
        number = str(issue.get("number") or "").strip()
        if not number:
            continue
        row = [number, fields["alarm"], fields["function"], fields["old"], fields["new"]]
        print("\t".join(row))
PY
}

file_one_canary_rollback_card() {
  local number="$1" alarm="$2" fn="$3" old="$4" new="$5"
  local slug title bodyf
  slug="$(canary_rollback_slug "$fn" "$old" "$new" "$number")"
  if canary_card_exists "$slug"; then
    canary_card_log "skip existing slug=$slug"
    return 0
  fi
  title="schema-canary-rollback ${fn} ${old} ${new}"
  bodyf="$(mktemp "${TMPDIR:-/tmp}/schema-canary-card.XXXXXX")"
  canary_rollback_card_body "$alarm" "$fn" "$old" "$new" "$SCHEMA_CANARY_CARD_REPO" >"$bodyf"
  if ! "$KANBAN_BIN" add "$slug" \
      --title "$title" \
      --column todo \
      --kind pr \
      --priority P1 \
      --repo "$SCHEMA_CANARY_CARD_REPO" \
      --base main \
      <"$bodyf"; then
    canary_card_log "kanban add failed slug=$slug"
    return 1
  fi
  if ! "$GH_BIN" issue comment "$number" --repo "$SCHEMA_CANARY_ISSUE_REPO" \
      --body "kanban:${slug}"; then
    canary_card_log "issue comment failed issue=$number slug=$slug (card exists)"
  fi
  canary_card_log "filed slug=$slug issue=$number"
  return 0
}

file_canary_rollback_cards() {
  local listf errf
  if ! command -v "$GH_BIN" >/dev/null 2>&1 && [ ! -x "$GH_BIN" ]; then
    canary_card_log "gh missing"
    return 1
  fi
  if ! command -v "$KANBAN_BIN" >/dev/null 2>&1 && [ ! -x "$KANBAN_BIN" ]; then
    canary_card_log "kanban missing"
    return 1
  fi
  listf="$(mktemp "${TMPDIR:-/tmp}/schema-canary-issues.XXXXXX")"
  errf="${listf}.err"
  if ! "$GH_BIN" issue list \
      --repo "$SCHEMA_CANARY_ISSUE_REPO" \
      --label schema-canary-rollback \
      --state open \
      --limit 50 \
      --json number,title,body >"$listf" 2>"$errf"; then
    canary_card_log "gh issue list failed"
    cat "$errf" >&2 || true
    return 1
  fi
  local number alarm fn old new rc=0
  while IFS="$(printf '\t')" read -r number alarm fn old new; do
    [ -n "${number:-}" ] || continue
    if ! file_one_canary_rollback_card "$number" "$alarm" "$fn" "$old" "$new"; then
      rc=1
    fi
  done <<EOF
$(parse_open_rollback_issues "$listf")
EOF
  return "$rc"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  file_canary_rollback_cards "$@"
fi
