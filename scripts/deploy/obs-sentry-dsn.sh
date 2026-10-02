#!/usr/bin/env bash
# Load OBS_SENTRY_DSN for a prod deploy from the GitHub Actions repository
# variable of the same name. Never print the value.
#
# Prod:
#   Call `gh variable get OBS_SENTRY_DSN`. On success with a non-empty
#   value, export it for CDK synth so it lands only in the Lambda
#   environment. On a failed or empty get, leave OBS_SENTRY_DSN unset.
# Non-prod:
#   Do not call gh. Leave the caller's OBS_SENTRY_DSN as it is.
#
# The GitHub workflow must not put this value in a step env map and must
# not add an `environment:` key. This script is the only reader.
#
# Usage (from deploy.sh):
#   # shellcheck source=scripts/deploy/obs-sentry-dsn.sh
#   source "$SCRIPT_DIR/scripts/deploy/obs-sentry-dsn.sh"
#   schema_load_obs_sentry_dsn "$ENVIRONMENT"
#
# Sourced by deploy.sh. Do not set -euo here: deploy.sh is `set -e` only.

schema_load_obs_sentry_dsn() {
  local env_name="${1:-}"
  local xtrace_on=0
  local token=""
  local repo=""
  local dsn=""

  case "$-" in
    *x*) xtrace_on=1 ;;
  esac
  set +x

  SCHEMA_OBS_SENTRY_DSN_SET=0
  if [ "$env_name" != "prod" ]; then
    if [ -n "${OBS_SENTRY_DSN:-}" ]; then
      SCHEMA_OBS_SENTRY_DSN_SET=1
    fi
    [ "$xtrace_on" -eq 1 ] && set -x
    return 0
  fi

  unset OBS_SENTRY_DSN || true
  token="${GH_TOKEN:-${GH_PAT:-${GITHUB_TOKEN:-}}}"
  repo="${GITHUB_REPOSITORY:-EdgeVector/schema-infra}"

  if [ -z "$token" ] || ! command -v gh >/dev/null 2>&1; then
    unset token dsn
    [ "$xtrace_on" -eq 1 ] && set -x
    return 0
  fi

  if dsn="$(
    GH_TOKEN="$token" GH_PROMPT_DISABLED=1 GIT_TERMINAL_PROMPT=0 \
      gh variable get OBS_SENTRY_DSN -R "$repo" 2>/dev/null
  )"; then
    dsn="${dsn#"${dsn%%[![:space:]]*}"}"
    dsn="${dsn%"${dsn##*[![:space:]]}"}"
    if [ -n "$dsn" ]; then
      export OBS_SENTRY_DSN="$dsn"
      SCHEMA_OBS_SENTRY_DSN_SET=1
    fi
  fi

  unset token dsn
  [ "$xtrace_on" -eq 1 ] && set -x
  return 0
}
