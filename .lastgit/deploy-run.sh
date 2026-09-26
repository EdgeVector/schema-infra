#!/usr/bin/env bash
# Supervise the post-merge deploy-pipeline deploy for schema-infra (main only) — Forgejo edition.
#
# Until 2026-09-06 this ran `lastgit ci watch --context deploy-pipeline`, which fired
# when LastGit recorded a green ci-required for a new main tip. The gate of
# record is Forgejo now (brain: decision-2026-09-06-all-repos-venue-forgejo-no-lastgit-default),
# so this polls refs/heads/main on the forge instead. When the tip changes and
# its Forge CI combined status is success, it clones that tip into a scratch
# dir and runs .lastgit/deploy-pipeline.sh there, one deploy at a time, then posts a
# `deploy-pipeline` commit status back to the forge so the deploy outcome stays visible
# on the commit the way the LastGit context row did.
#
# Deliberately NOT a Forge CI job: Forgejo cancels an in-progress push run when
# the next merge lands, and a production deploy must never be cut off mid-flight.
#
# The LaunchAgent runs this file from a forge-tracking checkout of the repo
# (install-deploy-launchd.sh points the plist at it). Whenever forge main moves
# past that checkout, the loop fast-forwards the checkout and, if this file's
# bytes changed, re-execs itself so a merged fix to the watcher takes effect
# without a hand copy. Same shape as fold_db_website #8 / exemem-infra #477.
set -euo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ORIG_ARGS=("$@")
REPO="${1:-schema-infra}"
CONTEXT="${LASTGIT_DEPLOY_CONTEXT:-deploy-pipeline}"
SCRIPT="${LASTGIT_DEPLOY_SCRIPT:-.lastgit/deploy-pipeline.sh}"
REF="${LASTGIT_DEPLOY_REF:-refs/heads/main}"
FORGE_ROOT="${FORGE_ROOT:-http://localhost:3300}"
FORGE_OWNER="${FORGE_OWNER:-EdgeVector}"
POLL_S="${LASTGIT_DEPLOY_POLL_S:-30}"
export PATH="${HOME}/.local/bin:${HOME}/.cargo/bin:${HOME}/.bun/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"
export LASTGIT_SOCKET="${LASTGIT_SOCKET:-${HOME}/.lastdb/data/folddb.sock}"
export LASTGIT_SCHEMA_MAP="${LASTGIT_SCHEMA_MAP:-$HOME/.lastgit/schema-map.json}"
LOG_DIR="${LASTGIT_DEPLOY_LOG_DIR:-$HOME/.lastgit/deploy-$REPO}"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/deploy.log"
STATE="$LOG_DIR/forge-deploy.last-oid"
export AWS_PROFILE="${AWS_PROFILE:-default}"
export SCHEMA_BUILD_REMOTE_HOST="${SCHEMA_BUILD_REMOTE_HOST:-pc}"
forge_token() {
  if [ -n "${FORGE_TOKEN:-}" ]; then printf '%s' "$FORGE_TOKEN"; return 0; fi
  if [ -f "$HOME/.last-stack/lib/forge-token.sh" ]; then
    # shellcheck disable=SC1091
    . "$HOME/.last-stack/lib/forge-token.sh"
    last_stack_forge_token && return 0
  fi
  security find-generic-password -s forgejo-token -w 2>/dev/null
}
TOKEN="$(forge_token || true)"
if [ -z "$TOKEN" ]; then
  echo "deploy-run: no forge token (keychain forgejo-token / lastsecrets://forgejo-token)" | tee -a "$LOG" >&2
  exit 1
fi
# Every child git (including the deploy script's own ls-remote against the
# forge) authenticates through GIT_CONFIG_* — no per-call header plumbing.
# Children that talk to the forge API or ship the token to the remote builder
# (scripts/remote-native-build.sh) read FORGE_TOKEN; hand it down too, so the
# deploy does not depend on a keychain item this host no longer has.
export FORGE_TOKEN="$TOKEN"
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0="http.${FORGE_ROOT}/.extraHeader"
export GIT_CONFIG_VALUE_0="Authorization: token ${TOKEN}"
export LASTGIT_DEPLOY_TIP_URL="${LASTGIT_DEPLOY_TIP_URL:-${FORGE_ROOT}/${FORGE_OWNER}/${REPO}.git}"

# Write token to a 0600 config file for curl instead of passing it on argv.
# This keeps the token off process argv, which is readable by every local account via ps aux.
AUTH_CONF_DIR="$(mktemp -d "${TMPDIR:-/tmp}/forge-deploy-auth.XXXXXX")"
AUTH_CONF="$AUTH_CONF_DIR/auth.conf"
printf 'header = "Authorization: token %s"\n' "$TOKEN" >"$AUTH_CONF"
chmod 600 "$AUTH_CONF"
trap "rm -rf '$AUTH_CONF_DIR'" EXIT

api() { curl -sS --max-time 30 -K "$AUTH_CONF" -H "Accept: application/json" "$@"; }
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$LOG"; }
self_sum() { shasum -a 256 "$SELF" 2>/dev/null | awk '{print $1}'; }
# Fast-forward the checkout this script runs from to the forge tip. git replaces
# files by rename, so the running bash keeps its old inode; re-exec picks up the
# new bytes. Skipped when ROOT is not a git checkout (ad-hoc runs).
refresh_checkout() {
  local want="$1" have before after
  [ -d "$ROOT/.git" ] || return 0
  have="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"
  [ -n "$have" ] && [ "$have" != "$want" ] || return 0
  before="$(self_sum)"
  # Serialize with the canary ticker wrapper, which fast-forwards the same
  # checkout (scripts/deploy/checkout-lock.sh). A timed-out wait is logged and
  # retried on the next tick, same as a failed pull.
  # shellcheck source=scripts/deploy/checkout-lock.sh
  [ -f "$ROOT/scripts/deploy/checkout-lock.sh" ] && source "$ROOT/scripts/deploy/checkout-lock.sh"
  if command -v checkout_lock_acquire >/dev/null 2>&1 && ! checkout_lock_acquire "$ROOT" "${CHECKOUT_LOCK_WAIT_S:-60}" 2>>"$LOG"; then
    log "deploy-run: checkout refresh skipped at $have (lock busy); see $LOG"
    return 0
  fi
  if ! timeout 120 git -C "$ROOT" pull -q --ff-only origin "${REF#refs/heads/}" >>"$LOG" 2>&1; then
    command -v checkout_lock_release >/dev/null 2>&1 && checkout_lock_release "$ROOT"
    log "deploy-run: checkout refresh failed at $have (keeping it); see $LOG"
    return 0
  fi
  command -v checkout_lock_release >/dev/null 2>&1 && checkout_lock_release "$ROOT"
  after="$(self_sum)"
  log "deploy-run: checkout $have -> $(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo '?')"
  if [ "$before" != "$after" ]; then
    log "deploy-run: script changed; re-exec $SELF"
    exec "$SELF" "${ORIG_ARGS[@]}"
  fi
}

log "deploy-run: repo=$REPO context=$CONTEXT venue=forgejo ref=$REF script=$SCRIPT root=$ROOT logs=$LOG_DIR poll=${POLL_S}s"
trap 'log "deploy-run: stopping"; exit 0' INT TERM
while true; do
  tip="$(timeout 60 git ls-remote "${FORGE_ROOT}/${FORGE_OWNER}/${REPO}.git" "$REF" 2>>"$LOG" | awk '{print $1}' | head -1 || true)"
  [ -n "$tip" ] && refresh_checkout "$tip"
  last="$(cat "$STATE" 2>/dev/null || true)"
  if [ -n "$tip" ] && [ "$tip" != "$last" ]; then
    state="$(api "${FORGE_ROOT}/api/v1/repos/${FORGE_OWNER}/${REPO}/commits/${tip}/status" 2>>"$LOG" | jq -r '.state // empty' 2>/dev/null || true)"
    if [ "$state" = "success" ]; then
      scratch="$(mktemp -d "${TMPDIR:-/tmp}/forge-deploy-${REPO}.XXXXXX")"
      log "deploy start oid=$tip context=$CONTEXT scratch=$scratch"
      rc=0
      (
        set -euo pipefail
        git clone -q --no-checkout "${FORGE_ROOT}/${FORGE_OWNER}/${REPO}.git" "$scratch"
        git -C "$scratch" checkout -q --detach "$tip"
        cd "$scratch"
        LASTGIT_CI_OID="$tip" LASTGIT_CI_CONTEXT="$CONTEXT" LASTGIT_CI_REPO="$REPO" bash "$SCRIPT"
      ) >>"$LOG" 2>&1 || rc=$?
      printf '%s\n' "$tip" > "$STATE"
      st=failure; [ "$rc" -eq 0 ] && st=success
      log "deploy $st oid=$tip rc=$rc"
      # Forgejo's create-status endpoint is /statuses/{sha}; the GitHub-shaped
      # /commits/{sha}/statuses answers 405 here. Keep the HTTP code visible so a
      # rejected post-back lands in the log instead of vanishing.
      code="$(api -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
        -d "{\"state\":\"$st\",\"context\":\"$CONTEXT\",\"description\":\"$CONTEXT rc=$rc (forge deploy watcher)\",\"target_url\":\"\"}" \
        "${FORGE_ROOT}/api/v1/repos/${FORGE_OWNER}/${REPO}/statuses/${tip}" 2>>"$LOG" || true)"
      case "$code" in 2*) ;; *) log "deploy status post-back failed http=$code oid=$tip context=$CONTEXT" ;; esac
      rm -rf "$scratch"
    elif [ -n "$state" ] && [ "$state" != "pending" ]; then
      log "tip $tip has Forge CI state=$state; not deploying"
      printf '%s\n' "$tip" > "$STATE"
    fi
  fi
  sleep "$POLL_S"
done
