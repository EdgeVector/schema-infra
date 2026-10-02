#!/usr/bin/env bash
# OBS_SENTRY_DSN is optional. Prod reads it via `gh variable get` inside
# the deploy helper. The value never prints. A failed or unset get leaves
# the Lambda DSN unset. Workflow YAML holds no step env map and no
# environment key.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$ROOT/scripts/deploy/obs-sentry-dsn.sh"
DEPLOY_YML="$ROOT/.github/workflows/deploy.yml"
TICKER_YML="$ROOT/.github/workflows/canary-ticker.yml"
DEPLOY_SH="$ROOT/deploy.sh"
test -f "$HELPER" || { echo "missing $HELPER" >&2; exit 1; }
test -f "$DEPLOY_YML" || { echo "missing $DEPLOY_YML" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/obs-sentry-dsn.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
export PATH="$TMP/bin:$PATH"

DSN_VALUE="https://dsn-fixture-deadbeef@o0.ingest.sentry.io/0"
export GITHUB_REPOSITORY="EdgeVector/schema-infra"

# shellcheck source=/dev/null
source "$HELPER"

write_gh() {
  local mode="$1"
  cat >"$TMP/bin/gh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "\$*" >>"$TMP/gh.args"
if [ "\${1:-}" != "variable" ] || [ "\${2:-}" != "get" ]; then
  echo "unexpected gh: \$*" >&2
  exit 9
fi
EOF
  case "$mode" in
    ok)
      cat >>"$TMP/bin/gh" <<EOF
printf '%s\\n' "$DSN_VALUE"
exit 0
EOF
      ;;
    empty)
      cat >>"$TMP/bin/gh" <<'EOF'
printf '%s\n' ""
exit 0
EOF
      ;;
    fail)
      cat >>"$TMP/bin/gh" <<'EOF'
echo "variable not found" >&2
exit 1
EOF
      ;;
  esac
  chmod +x "$TMP/bin/gh"
}

assert_no_dsn_in() {
  local file="$1" label="$2"
  if grep -F -q "$DSN_VALUE" "$file" 2>/dev/null; then
    echo "FAIL $label leaked DSN:" >&2
    cat "$file" >&2
    exit 1
  fi
}

# 1. Prod + successful get: export for Lambda, never print.
write_gh ok
: >"$TMP/gh.args"
unset OBS_SENTRY_DSN SCHEMA_OBS_SENTRY_DSN_SET || true
export GH_PAT="pat-fixture"
(
  schema_load_obs_sentry_dsn prod
  if [ "${OBS_SENTRY_DSN:-}" != "$DSN_VALUE" ]; then
    echo "FAIL prod ok: expected DSN in process env for CDK" >&2
    exit 1
  fi
  if [ "${SCHEMA_OBS_SENTRY_DSN_SET:-0}" != "1" ]; then
    echo "FAIL prod ok: SCHEMA_OBS_SENTRY_DSN_SET" >&2
    exit 1
  fi
  python3 - "$TMP/lambda-payload" <<'PY'
import os, sys
path = sys.argv[1]
dsn = os.environ.get("OBS_SENTRY_DSN", "")
# Record only whether the Lambda payload would receive a value.
open(path, "w").write("set\n" if dsn else "unset\n")
PY
) >"$TMP/out.ok" 2>"$TMP/err.ok"
[ "$(cat "$TMP/lambda-payload")" = "set" ] || {
  echo "FAIL prod ok: Lambda payload marker" >&2
  exit 1
}
grep -q 'variable get OBS_SENTRY_DSN' "$TMP/gh.args" || {
  echo "FAIL prod ok: gh variable get was not called" >&2
  cat "$TMP/gh.args" >&2
  exit 1
}
if grep -E -q '(^| )https://' "$TMP/gh.args"; then
  echo "FAIL prod ok: DSN must not appear on gh argv" >&2
  cat "$TMP/gh.args" >&2
  exit 1
fi
assert_no_dsn_in "$TMP/out.ok" "prod ok stdout"
assert_no_dsn_in "$TMP/err.ok" "prod ok stderr"

# 2. bash -x must not print the value.
write_gh ok
unset OBS_SENTRY_DSN SCHEMA_OBS_SENTRY_DSN_SET || true
set +e
bash -x -c '
  source "$1"
  schema_load_obs_sentry_dsn prod
' _ "$HELPER" >"$TMP/out.xtrace" 2>"$TMP/err.xtrace"
set -e
assert_no_dsn_in "$TMP/out.xtrace" "xtrace stdout"
assert_no_dsn_in "$TMP/err.xtrace" "xtrace stderr"

# 3. Prod + failed get: leave unset even if a leftover env value exists.
write_gh fail
export OBS_SENTRY_DSN="leftover-must-not-win"
unset SCHEMA_OBS_SENTRY_DSN_SET || true
schema_load_obs_sentry_dsn prod >"$TMP/out.fail" 2>"$TMP/err.fail"
if [ -n "${OBS_SENTRY_DSN+x}" ] && [ -n "${OBS_SENTRY_DSN:-}" ]; then
  echo "FAIL prod fail: DSN must be unset after a failed get" >&2
  exit 1
fi
[ "${SCHEMA_OBS_SENTRY_DSN_SET:-0}" = "0" ] || {
  echo "FAIL prod fail: SCHEMA_OBS_SENTRY_DSN_SET" >&2
  exit 1
}
assert_no_dsn_in "$TMP/out.fail" "prod fail stdout"
assert_no_dsn_in "$TMP/err.fail" "prod fail stderr"

# 4. Prod + empty get: leave unset.
write_gh empty
unset OBS_SENTRY_DSN SCHEMA_OBS_SENTRY_DSN_SET || true
schema_load_obs_sentry_dsn prod
if [ -n "${OBS_SENTRY_DSN:-}" ]; then
  echo "FAIL prod empty: DSN must be unset" >&2
  exit 1
fi

# 5. Prod + no token: leave unset, do not require gh.
rm -f "$TMP/bin/gh"
unset OBS_SENTRY_DSN GH_TOKEN GH_PAT GITHUB_TOKEN SCHEMA_OBS_SENTRY_DSN_SET || true
schema_load_obs_sentry_dsn prod
if [ -n "${OBS_SENTRY_DSN:-}" ]; then
  echo "FAIL prod no-token: DSN must be unset" >&2
  exit 1
fi

# 6. Dev does not call gh and keeps a caller-supplied value.
write_gh ok
: >"$TMP/gh.args"
export OBS_SENTRY_DSN="dev-local-dsn"
schema_load_obs_sentry_dsn dev
[ "${OBS_SENTRY_DSN:-}" = "dev-local-dsn" ] || {
  echo "FAIL dev: must leave caller DSN in place" >&2
  exit 1
}
if [ -s "$TMP/gh.args" ]; then
  echo "FAIL dev: gh must not run" >&2
  cat "$TMP/gh.args" >&2
  exit 1
fi

# 7. Workflow YAML: no environment key, no step env map, no vars interpolation.
for yml in "$DEPLOY_YML" "$TICKER_YML"; do
  if grep -E '^[[:space:]]+environment:' "$yml"; then
    echo "FAIL $yml adds an environment key" >&2
    exit 1
  fi
  if grep -F 'vars.OBS_SENTRY_DSN' "$yml" | grep -v '^[[:space:]]*#'; then
    echo "FAIL $yml interpolates vars.OBS_SENTRY_DSN" >&2
    exit 1
  fi
  if grep -E '^[[:space:]]+OBS_SENTRY_DSN:' "$yml" | grep -v '^[[:space:]]*#'; then
    echo "FAIL $yml puts OBS_SENTRY_DSN in a step env map" >&2
    exit 1
  fi
done

# 8. deploy.sh sources the helper and loads for the target environment.
grep -q 'obs-sentry-dsn.sh' "$DEPLOY_SH" || {
  echo "FAIL deploy.sh does not source obs-sentry-dsn.sh" >&2
  exit 1
}
grep -q 'schema_load_obs_sentry_dsn' "$DEPLOY_SH" || {
  echo "FAIL deploy.sh does not call schema_load_obs_sentry_dsn" >&2
  exit 1
}
if grep -E 'echo .*OBS_SENTRY_DSN' "$DEPLOY_SH" | grep -v 'Sentry DSN:'; then
  echo "FAIL deploy.sh must not echo OBS_SENTRY_DSN" >&2
  exit 1
fi

echo "ok obs-sentry-dsn"
