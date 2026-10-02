#!/usr/bin/env bash
# Load OBS_SENTRY_DSN from the GitHub Actions repository variable when the
# process env does not already hold it. Never print the value. On a failed
# get, leave the Lambda DSN unset. No Sentry project is created here.
#
# Sourced by deploy.sh. The workflow YAML must not put this value in a step
# env map and must not add an environment: key.
schema_load_obs_sentry_dsn() {
  if [ -n "${OBS_SENTRY_DSN:-}" ]; then
    return 0
  fi
  if ! command -v gh >/dev/null 2>&1; then
    return 0
  fi
  local repo dsn rc=0
  repo="${GITHUB_REPOSITORY:-EdgeVector/schema-infra}"
  case "$-" in
    *x*) set +x ;;
  esac
  dsn="$(gh variable get OBS_SENTRY_DSN --repo "$repo" 2>/dev/null)" || rc=$?
  if [ "$rc" -eq 0 ] && [ -n "$dsn" ]; then
    OBS_SENTRY_DSN="$dsn"
    export OBS_SENTRY_DSN
  fi
  return 0
}
