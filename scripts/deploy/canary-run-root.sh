#!/usr/bin/env bash
# Refresh + assert the schema-infra canary ticker run-root.
# Sourced by canary-ticker.sh and the durable launchd wrapper.
#
# Production promotion must not run July-vintage dirty clones. Fetch the
# canonical remote's main, fast-forward only, and fail closed on dirty or
# still-stale trees. lastgit is preferred; origin (GitHub mirror) is fallback.
set -euo pipefail

CANARY_RUN_ROOT_MAX_BEHIND="${CANARY_RUN_ROOT_MAX_BEHIND:-0}"

canary_run_root_log() {
  local line="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
  echo "$line"
  if [ -n "${LASTGIT_DEPLOY_LOG_DIR:-}" ]; then
    mkdir -p "$LASTGIT_DEPLOY_LOG_DIR"
    echo "$line" >>"${LASTGIT_DEPLOY_LOG_DIR}/canary.log"
  fi
}

canary_run_root_remote() {
  local root="$1"
  if git -C "$root" remote get-url lastgit >/dev/null 2>&1; then
    printf '%s\n' lastgit
    return 0
  fi
  if git -C "$root" remote get-url origin >/dev/null 2>&1; then
    printf '%s\n' origin
    return 0
  fi
  echo "FAIL: canary run-root has no lastgit or origin remote: $root" >&2
  return 1
}

# Forge credentials for unattended fetches. The inherited osxkeychain helper
# fails under launchd once the login keychain locks (-25293), and git then
# prompts for a username and the ticker goes blind
# (papercut-schema-infra-canary-ticker-fetch-fails-keychain-since-20260923).
# The last-stack forge helper reads the token without the keychain.
CANARY_FORGE_ROOT="${FORGE_ROOT:-http://localhost:3300}"
# Literal $HOME: git runs a "!" helper through the shell, so the value stays
# valid for the user that owns the checkout.
# shellcheck disable=SC2016
CANARY_FORGE_HELPER_VALUE='!"$HOME/.last-stack/bin/git-credential-last-stack-forge"'

canary_forge_helper_present() {
  [ -x "${HOME}/.last-stack/bin/git-credential-last-stack-forge" ]
}

# Register the forge helper in the checkout's own .git/config: an empty entry
# resets the inherited helper chain (osxkeychain), then the forge helper.
# Idempotent. Called by both launchd installers.
canary_register_forge_credential_helper() {
  local root="${1:?canary_register_forge_credential_helper requires a checkout path}"
  local key="credential.${CANARY_FORGE_ROOT}.helper"
  if ! canary_forge_helper_present; then
    echo "WARN: ~/.last-stack/bin/git-credential-last-stack-forge missing; forge fetches in $root use the inherited helper" >&2
    return 0
  fi
  git -C "$root" config --unset-all "$key" 2>/dev/null || true
  git -C "$root" config --add "$key" ""
  git -C "$root" config --add "$key" "$CANARY_FORGE_HELPER_VALUE"
}

canary_run_root_fetch() {
  local root="$1" remote="$2"
  local spec="+refs/heads/main:refs/remotes/${remote}/main"
  if [ "${CANARY_SKIP_FETCH:-}" = "1" ]; then
    return 0
  fi
  if canary_forge_helper_present; then
    # Same reset + helper on the command line, so a checkout whose config
    # lost the entry (re-clone, hand edit) still fetches without a keychain.
    GIT_TERMINAL_PROMPT=0 git -C "$root" \
      -c "credential.${CANARY_FORGE_ROOT}.helper=" \
      -c "credential.${CANARY_FORGE_ROOT}.helper=${CANARY_FORGE_HELPER_VALUE}" \
      fetch --quiet "$remote" "$spec"
  else
    GIT_TERMINAL_PROMPT=0 git -C "$root" fetch --quiet "$remote" "$spec"
  fi
}

canary_assert_run_root_fresh() {
  local root="${1:?canary_assert_run_root_fresh requires a checkout path}"
  local remote main_ref want have behind
  if [ ! -d "$root/.git" ] && [ ! -f "$root/.git" ]; then
    echo "FAIL: canary run-root is not a git checkout: $root" >&2
    return 1
  fi
  if [ -n "$(git -C "$root" status --porcelain 2>/dev/null)" ]; then
    echo "FAIL: canary run-root is dirty; refuse to run local/stale code: $root" >&2
    git -C "$root" status -sb >&2
    return 1
  fi
  remote="$(canary_run_root_remote "$root")"
  main_ref="refs/remotes/${remote}/main"
  if ! git -C "$root" rev-parse --verify "$main_ref" >/dev/null 2>&1; then
    echo "FAIL: canary run-root missing ${remote}/main; fetch before promote: $root" >&2
    return 1
  fi
  want="$(git -C "$root" rev-parse "$main_ref")"
  have="$(git -C "$root" rev-parse HEAD)"
  behind="$(git -C "$root" rev-list --count HEAD.."${main_ref}")"
  if [ "$want" != "$have" ] || [ "$behind" -gt "$CANARY_RUN_ROOT_MAX_BEHIND" ]; then
    echo "FAIL: canary run-root is stale vs ${remote}/main (HEAD=$have ${remote}/main=$want behind=$behind max=$CANARY_RUN_ROOT_MAX_BEHIND)" >&2
    return 1
  fi
  return 0
}

canary_refresh_run_root() {
  # Serialized with the deploy watcher, which fast-forwards the same checkout.
  local root="${1:?canary_refresh_run_root requires a checkout path}"
  # The lock lib lives in the checkout being refreshed; the durable wrapper
  # sources a COPY of this file from LOG_DIR, so look in the run-root first,
  # then beside this file (the installer copies the lib there too).
  local lib
  for lib in "$root/scripts/deploy/checkout-lock.sh" "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/checkout-lock.sh"; do
    # shellcheck source=scripts/deploy/checkout-lock.sh
    if [ -f "$lib" ]; then source "$lib"; break; fi
  done
  if command -v with_checkout_lock >/dev/null 2>&1; then
    with_checkout_lock "$root" "${CHECKOUT_LOCK_WAIT_S:-60}" canary_refresh_run_root_unlocked "$root"
  else
    canary_refresh_run_root_unlocked "$root"
  fi
}

canary_refresh_run_root_unlocked() {
  local root="${1:?canary_refresh_run_root requires a checkout path}"
  local remote main_ref want have
  if [ ! -d "$root/.git" ] && [ ! -f "$root/.git" ]; then
    echo "FAIL: canary run-root is not a git checkout: $root" >&2
    return 1
  fi
  if [ -n "$(git -C "$root" status --porcelain 2>/dev/null)" ]; then
    echo "FAIL: canary run-root is dirty; refuse to refresh or run: $root" >&2
    git -C "$root" status -sb >&2
    return 1
  fi
  remote="$(canary_run_root_remote "$root")"
  if ! canary_run_root_fetch "$root" "$remote"; then
    echo "FAIL: fetch ${remote}/main failed for canary run-root $root" >&2
    return 1
  fi
  main_ref="refs/remotes/${remote}/main"
  if ! git -C "$root" rev-parse --verify "$main_ref" >/dev/null 2>&1; then
    echo "FAIL: canary run-root has no ${remote}/main after fetch: $root" >&2
    return 1
  fi
  want="$(git -C "$root" rev-parse "$main_ref")"
  have="$(git -C "$root" rev-parse HEAD)"
  if [ "$want" != "$have" ]; then
    if git -C "$root" merge-base --is-ancestor "$have" "$want"; then
      git -C "$root" merge --ff-only --quiet "$main_ref"
    else
      echo "FAIL: canary run-root HEAD $have is not an ancestor of ${remote}/main $want" >&2
      return 1
    fi
  fi
  canary_assert_run_root_fresh "$root"
  have="$(git -C "$root" rev-parse HEAD)"
  canary_run_root_log "canary: run-root fresh HEAD=$have remote=$remote"
}
