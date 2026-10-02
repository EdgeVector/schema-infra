#!/usr/bin/env bash
# Unit test: the host-local routine files one kanban card per rollback issue
# and does not file a second card for the same slug.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/deploy/canary-rollback-card.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export PATH="$TMP/bin:$PATH"
export CANARY_ROLLBACK_REPO="EdgeVector/schema-infra"
mkdir -p "$TMP/bin" "$TMP/kanban"

cat >"$TMP/issue.json" <<'EOF'
[
  {
    "number": 7,
    "body": "alarm: schema-mutation-gate-hourly-quota-prod\nfunction: SchemaFn\nold: 12\nnew: 13\n"
  }
]
EOF

cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${MOCK_GH_LOG}"
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "list" ]; then
  cat "${MOCK_ISSUE_JSON}"
  exit 0
fi
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "comment" ]; then
  exit 0
fi
exit 0
EOF
chmod +x "$TMP/bin/gh"

cat >"$TMP/bin/kanban" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${MOCK_KANBAN_LOG}"
if [ "${1:-}" = "show" ]; then
  slug="$2"
  if [ -f "${MOCK_KANBAN_DIR}/${slug}" ]; then
    exit 0
  fi
  exit 1
fi
if [ "${1:-}" = "add" ]; then
  slug="$2"
  body=""
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "--body" ]; then body="${2:-}"; break; fi
    shift
  done
  printf '%s\n' "$body" >"${MOCK_KANBAN_DIR}/${slug}"
  echo "$slug" >>"${MOCK_KANBAN_ADDED}"
  exit 0
fi
exit 1
EOF
chmod +x "$TMP/bin/kanban"

export MOCK_GH_LOG="$TMP/gh.log"
export MOCK_KANBAN_LOG="$TMP/kanban.log"
export MOCK_KANBAN_DIR="$TMP/kanban"
export MOCK_KANBAN_ADDED="$TMP/added"
export MOCK_ISSUE_JSON="$TMP/issue.json"
: >"$MOCK_GH_LOG"
: >"$MOCK_KANBAN_LOG"
: >"$MOCK_KANBAN_ADDED"

bash "$SCRIPT"
slug="schema-canary-rollback-schemafn-v12-v13-7"
grep -qx "$slug" "$MOCK_KANBAN_ADDED" || {
  echo "expected first pass to file $slug:" >&2
  cat "$MOCK_KANBAN_ADDED" >&2
  exit 1
}
body="$MOCK_KANBAN_DIR/$slug"
grep -q 'alarm: schema-mutation-gate-hourly-quota-prod' "$body" || {
  echo "card must name the alarm" >&2
  cat "$body" >&2
  exit 1
}
grep -q 'function: SchemaFn' "$body" || { echo "card must name the function" >&2; exit 1; }
grep -q 'old: 12' "$body" || { echo "card must name the old version" >&2; exit 1; }
grep -q 'new: 13' "$body" || { echo "card must name the new version" >&2; exit 1; }
grep -q '## GOAL' "$body" || { echo "card must have GOAL" >&2; exit 1; }
grep -q '## END STATE' "$body" || { echo "card must have END STATE" >&2; exit 1; }
grep -q '^Repo: EdgeVector/schema-infra$' "$body" || {
  echo "card must have a bare Repo line:" >&2
  cat "$body" >&2
  exit 1
}
if grep -qi 'north.star' "$body"; then
  echo "card must not invent a North Star" >&2
  exit 1
fi
grep -q 'issue comment 7' "$MOCK_GH_LOG" || {
  echo "successful add must comment the issue:" >&2
  cat "$MOCK_GH_LOG" >&2
  exit 1
}

# Second pass: slug exists, do not add another card.
: >"$MOCK_KANBAN_ADDED"
: >"$MOCK_GH_LOG"
bash "$SCRIPT"
if [ -s "$MOCK_KANBAN_ADDED" ]; then
  echo "second pass must not add another card:" >&2
  cat "$MOCK_KANBAN_ADDED" >&2
  exit 1
fi
if grep -q 'issue comment' "$MOCK_GH_LOG"; then
  echo "second pass must not comment again" >&2
  cat "$MOCK_GH_LOG" >&2
  exit 1
fi

echo "ok canary-rollback-card"
