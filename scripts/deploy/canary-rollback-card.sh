#!/usr/bin/env bash
# Host-local routine: file one kanban card per open GitHub issue labeled
# schema-canary-rollback. The GitHub-hosted ticker cannot open the LastDB
# socket, so this process is the only board writer.
#
# Idempotent: if slug schema-canary-rollback-<fn>-v<old>-v<new>-<issue>
# already exists, do not add another card. After a successful add, comment
# the slug on the issue. Do not set a North Star.
set -euo pipefail

REPO="${CANARY_ROLLBACK_REPO:-EdgeVector/schema-infra}"
LABEL="schema-canary-rollback"
KANBAN_BIN="${CANARY_ROLLBACK_KANBAN:-kanban}"
GH_BIN="${CANARY_ROLLBACK_GH:-gh}"

canary_rollback_slug() {
  local fn="$1" old="$2" new="$3" issue="$4"
  local safe
  safe="$(printf '%s' "$fn" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g; s/--*/-/g; s/^-//; s/-$//')"
  [ -n "$safe" ] || safe="fn"
  printf 'schema-canary-rollback-%s-v%s-v%s-%s\n' "$safe" "$old" "$new" "$issue"
}

canary_rollback_card_body() {
  local alarm="$1" fn="$2" old="$3" new="$4"
  cat <<EOF
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

Repo: ${REPO}
EOF
}

canary_rollback_card_exists() {
  local slug="$1"
  "$KANBAN_BIN" show "$slug" >/dev/null 2>&1
}

canary_rollback_file_one() {
  local number="$1" alarm="$2" fn="$3" old="$4" new="$5"
  local slug body_file title
  slug="$(canary_rollback_slug "$fn" "$old" "$new" "$number")"
  if canary_rollback_card_exists "$slug"; then
    echo "canary-rollback-card: skip existing $slug"
    return 0
  fi
  body_file="$(mktemp "${TMPDIR:-/tmp}/canary-rollback-card.XXXXXX")"
  canary_rollback_card_body "$alarm" "$fn" "$old" "$new" >"$body_file"
  title="schema canary rollback ${fn} ${old} ${new}"
  if ! "$KANBAN_BIN" add "$slug" --title "$title" --column todo --body "$(cat "$body_file")"; then
    echo "canary-rollback-card: kanban add failed for $slug" >&2
    return 1
  fi
  "$GH_BIN" issue comment "$number" --repo "$REPO" --body "kanban: ${slug}" >/dev/null
  echo "canary-rollback-card: filed $slug from issue $number"
}

canary_rollback_process_issues() {
  local json
  json="$("$GH_BIN" issue list --repo "$REPO" --label "$LABEL" --state open --json number,body)"
  # Heredoc is python stdin, so the issue JSON goes in argv.
  python3 - "$json" <<'PY'
import json, sys
raw = sys.argv[1] if len(sys.argv) > 1 else ""
if not raw.strip():
    raise SystemExit(0)
try:
    issues = json.loads(raw)
except Exception:
    raise SystemExit(0)
if not isinstance(issues, list):
    raise SystemExit(0)
for issue in issues:
    number = issue.get("number")
    body = issue.get("body") or ""
    fields = {}
    for line in body.splitlines():
        if ":" not in line:
            continue
        key, val = line.split(":", 1)
        key = key.strip().lower()
        if key in ("alarm", "function", "old", "new") and key not in fields:
            fields[key] = val.strip()
    alarm = fields.get("alarm") or ""
    fn = fields.get("function") or ""
    old = fields.get("old") or ""
    new = fields.get("new") or ""
    if not (number and alarm and fn and old and new):
        continue
    print("%s\t%s\t%s\t%s\t%s" % (number, alarm, fn, old, new))
PY
}

if [ "${CANARY_ROLLBACK_CARD_SOURCED:-}" = "1" ]; then
  return 0
fi

if ! command -v "$GH_BIN" >/dev/null 2>&1; then
  echo "canary-rollback-card: gh is required" >&2
  exit 1
fi
if ! command -v "$KANBAN_BIN" >/dev/null 2>&1; then
  echo "canary-rollback-card: kanban is required" >&2
  exit 1
fi

rows="$(canary_rollback_process_issues || true)"
if [ -z "${rows:-}" ]; then
  echo "canary-rollback-card: no open $LABEL issues"
  exit 0
fi

fail=0
while IFS="$(printf '\t')" read -r number alarm fn old new; do
  [ -n "${number:-}" ] || continue
  if ! canary_rollback_file_one "$number" "$alarm" "$fn" "$old" "$new"; then
    fail=1
  fi
done <<EOF
$rows
EOF
exit "$fail"
