#!/usr/bin/env bash
# Local routine files one kanban card per schema-canary-rollback issue.
# The card has GOAL, END STATE, and a bare Repo line. No North Star.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/scripts/deploy/file-canary-rollback-cards.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/canary-card.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export PATH="$TMP/bin:$PATH"
mkdir -p "$TMP/bin" "$TMP/slugs"

cat >"$TMP/issues.json" <<'EOF'
[
  {
    "number": 44,
    "title": "schema-canary-rollback SchemaFn 12 13",
    "body": "alarm: schema-mutation-gate-hourly-quota-prod\nfunction: SchemaFn\nold: 12\nnew: 13\n"
  }
]
EOF

cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >>"${MOCK_GH_LOG}"
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "list" ]; then
  cat "${MOCK_ISSUE_LIST}"
  exit 0
fi
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "comment" ]; then
  printf '%s\n' "$@" >"${MOCK_GH_COMMENT}"
  exit 0
fi
exit 0
EOF
chmod +x "$TMP/bin/gh"

cat >"$TMP/bin/kanban" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >>"${MOCK_KANBAN_LOG}"
cmd="${1:-}"
shift || true
if [ "$cmd" = "show" ]; then
  slug="${1:-}"
  if [ -f "${MOCK_KANBAN_SLUGS}/${slug}" ]; then
    exit 0
  fi
  exit 1
fi
if [ "$cmd" = "add" ]; then
  slug="${1:-}"
  printf '%s\n' "$cmd" "$@" >"${MOCK_KANBAN_ADD_ARGV}"
  cat >"${MOCK_KANBAN_ADD_BODY}"
  mkdir -p "${MOCK_KANBAN_SLUGS}"
  cp "${MOCK_KANBAN_ADD_BODY}" "${MOCK_KANBAN_SLUGS}/${slug}"
  exit 0
fi
exit 1
EOF
chmod +x "$TMP/bin/kanban"

export MOCK_GH_LOG="$TMP/gh.log"
export MOCK_GH_COMMENT="$TMP/gh-comment"
export MOCK_ISSUE_LIST="$TMP/issues.json"
export MOCK_KANBAN_LOG="$TMP/kanban.log"
export MOCK_KANBAN_ADD_ARGV="$TMP/kanban-argv"
export MOCK_KANBAN_ADD_BODY="$TMP/kanban-body"
export MOCK_KANBAN_SLUGS="$TMP/slugs"
: >"$MOCK_GH_LOG"
: >"$MOCK_KANBAN_LOG"

# shellcheck source=/dev/null
source "$SRC"

file_canary_rollback_cards

slug="schema-canary-rollback-schemafn-v12-v13-44"
test -f "$MOCK_KANBAN_SLUGS/$slug" || {
  echo "expected card slug $slug" >&2
  ls "$MOCK_KANBAN_SLUGS" >&2
  exit 1
}
grep -q -- '--north-star' "$MOCK_KANBAN_ADD_ARGV" && {
  echo "filer must not set a North Star:" >&2
  cat "$MOCK_KANBAN_ADD_ARGV" >&2
  exit 1
}
grep -q 'Repo: EdgeVector/schema-infra' "$MOCK_KANBAN_ADD_BODY" || {
  echo "card body must have a bare Repo line:" >&2
  cat "$MOCK_KANBAN_ADD_BODY" >&2
  exit 1
}
grep -q '## GOAL' "$MOCK_KANBAN_ADD_BODY" || { echo "missing GOAL" >&2; exit 1; }
grep -q '## END STATE' "$MOCK_KANBAN_ADD_BODY" || { echo "missing END STATE" >&2; exit 1; }
grep -q 'alarm: schema-mutation-gate-hourly-quota-prod' "$MOCK_KANBAN_ADD_BODY" || {
  echo "card must name the alarm" >&2
  exit 1
}
grep -q 'function: SchemaFn' "$MOCK_KANBAN_ADD_BODY" || { echo "card must name the function" >&2; exit 1; }
grep -q 'old: 12' "$MOCK_KANBAN_ADD_BODY" || { echo "card must name the old version" >&2; exit 1; }
grep -q 'new: 13' "$MOCK_KANBAN_ADD_BODY" || { echo "card must name the new version" >&2; exit 1; }
grep -q "kanban:${slug}" "$MOCK_GH_COMMENT" || {
  echo "filer must comment the slug on the issue:" >&2
  cat "$MOCK_GH_COMMENT" >&2
  exit 1
}

# Second pass must not add another card.
: >"$MOCK_KANBAN_ADD_ARGV"
file_canary_rollback_cards
if [ -s "$MOCK_KANBAN_ADD_ARGV" ]; then
  echo "existing slug must not be filed again:" >&2
  cat "$MOCK_KANBAN_ADD_ARGV" >&2
  exit 1
fi

echo "ok file-canary-rollback-cards"
