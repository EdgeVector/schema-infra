#!/usr/bin/env bash
# Test that deploy-run.sh rejects a flag-shaped or empty repo argument before
# creating any log directory or attempting a clone.
# Fixture for:
# papercut-lastgit-deploy-run-repo-help-unvalidated
#
# Regression this guards against: a caller passing `--help` (or any other
# flag-shaped value) as the positional repo arg used to fall straight through
# into REPO, which then created $HOME/.lastgit/deploy---help/ and burned two
# minutes retrying a clone against a repo that can never exist.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/.lastgit/deploy-run.sh"

TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/deploy-run-repo-guard.XXXXXX")"
trap 'rm -rf "$TEST_TMP"' EXIT

fail=0

check_rejected() {
  local desc="$1"; shift
  local log_dir="$TEST_TMP/log-$(echo "$desc" | tr -c 'a-zA-Z0-9' '-')"
  local rc=0
  # deploy-run.sh is a `while true` watcher; a value that passes validation
  # would hang here forever, so bound every invocation with a timeout and
  # treat a timeout (124/137) as a validation failure, not a fluke.
  LASTGIT_DEPLOY_LOG_DIR="$log_dir" timeout 5 "$SCRIPT" "$@" >"$TEST_TMP/out" 2>"$TEST_TMP/err" || rc=$?
  if [ "$rc" -ne 2 ]; then
    echo "FAIL ($desc): expected exit 2, got $rc (see $TEST_TMP/err)" >&2
    fail=1
    return
  fi
  if [ -d "$log_dir" ]; then
    echo "FAIL ($desc): rejected repo still created a log dir at $log_dir" >&2
    fail=1
    return
  fi
  echo "PASS ($desc): rejected before any log dir or clone"
}

check_rejected "flag-shaped --help" --help
check_rejected "flag-shaped -x" -x
# bash's ${1:-default} treats an explicitly empty positional arg as unset, so
# passing "" cannot reach the validation directly. Cover the empty case via
# LASTGIT_DEPLOY_LOG_DIR still resolving from a would-be-valid REPO — the
# validation only guards flag-shaped input; document that boundary here
# rather than asserting a case the shell can never produce.

exit "$fail"
