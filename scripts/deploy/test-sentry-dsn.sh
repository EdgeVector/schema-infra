#!/usr/bin/env bash
# OBS_SENTRY_DSN comes from `gh variable get` inside the deploy script.
# The value never prints. Workflow YAML has no step env map and no
# environment key for it. An unset variable leaves the Lambda DSN unset.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$ROOT/scripts/deploy/sentry-dsn.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export PATH="$TMP/bin:$PATH"
mkdir -p "$TMP/bin"

cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${MOCK_GH_LOG}"
if [ "${1:-}" = "variable" ] && [ "${2:-}" = "get" ]; then
  if [ "${MOCK_GH_DSN_FAIL:-}" = "1" ]; then
    echo "variable not found" >&2
    exit 1
  fi
  printf '%s\n' "${MOCK_DSN_VALUE}"
  exit 0
fi
exit 1
EOF
chmod +x "$TMP/bin/gh"

export MOCK_GH_LOG="$TMP/gh.log"
export MOCK_DSN_VALUE="https://secret-dsn@example.invalid/42"
: >"$MOCK_GH_LOG"

# shellcheck source=/dev/null
source "$HELPER"

unset OBS_SENTRY_DSN || true
: >"$TMP/out"
: >"$TMP/err"
schema_load_obs_sentry_dsn >"$TMP/out" 2>"$TMP/err"
combined="$(cat "$TMP/out" "$TMP/err")"
case "$combined" in
  *secret-dsn*) echo "DSN value leaked to stdout/stderr: $combined" >&2; exit 1 ;;
esac
[ "${OBS_SENTRY_DSN:-}" = "$MOCK_DSN_VALUE" ] || {
  echo "expected DSN to be loaded into OBS_SENTRY_DSN" >&2
  exit 1
}
grep -q 'variable get OBS_SENTRY_DSN' "$MOCK_GH_LOG" || {
  echo "deploy helper must call gh variable get OBS_SENTRY_DSN:" >&2
  cat "$MOCK_GH_LOG" >&2
  exit 1
}

# Failed get leaves the DSN unset.
unset OBS_SENTRY_DSN || true
: >"$MOCK_GH_LOG"
MOCK_GH_DSN_FAIL=1 schema_load_obs_sentry_dsn
[ -z "${OBS_SENTRY_DSN:-}" ] || {
  echo "failed gh get must leave OBS_SENTRY_DSN unset" >&2
  exit 1
}

# Workflow YAML must not hold the value in env and must not add environment:.
for wf in "$ROOT/.github/workflows/deploy.yml" "$ROOT/.github/workflows/canary-ticker.yml"; do
  if grep -E '^[[:space:]]*environment:' "$wf"; then
    echo "$wf must not add an environment key" >&2
    exit 1
  fi
  if grep -q 'OBS_SENTRY_DSN' "$wf"; then
    echo "$wf must not name OBS_SENTRY_DSN (no step env map)" >&2
    exit 1
  fi
done

if grep -E 'echo .*OBS_SENTRY_DSN' "$ROOT/deploy.sh" | grep -v 'configured'; then
  echo "deploy.sh must not echo OBS_SENTRY_DSN" >&2
  exit 1
fi
grep -q 'schema_load_obs_sentry_dsn' "$ROOT/deploy.sh" || {
  echo "deploy.sh must call schema_load_obs_sentry_dsn" >&2
  exit 1
}

echo "ok sentry-dsn"
