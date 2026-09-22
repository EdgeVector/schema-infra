#!/usr/bin/env bash
# Serialize writers of a shared deploy checkout.
#
# The deploy watcher (.lastgit/deploy-run.sh) and the canary ticker wrapper
# (canary-run-root.sh) both fast-forward ~/.lastgit/deploy-checkouts/schema-infra
# to forge main. Two concurrent fetches of the same ref collide on git's ref
# lock ("cannot lock ref" / ".lock: File exists") and one side fails for a tick.
# macOS ships no flock(1), so this is a mkdir lock: mkdir is atomic, the dir
# holds the owner pid, and a lock whose pid is dead is broken.
#
#   checkout_lock_acquire <checkout> [wait_s]   → 0 held, 1 timed out
#   checkout_lock_release <checkout>
#   with_checkout_lock <checkout> <wait_s> cmd...  → runs cmd under the lock
#
# Source this file; it defines functions only.

checkout_lock_path() { printf '%s/.git/edgevector-checkout.lock' "$1"; }

checkout_lock_acquire() {
  local root="$1" wait_s="${2:-60}" lock owner i=0
  lock="$(checkout_lock_path "$root")"
  [ -d "$root/.git" ] || return 0   # not a checkout; nothing to serialize
  while :; do
    if mkdir "$lock" 2>/dev/null; then
      printf '%s\n' "$$" >"$lock/pid"
      return 0
    fi
    owner="$(cat "$lock/pid" 2>/dev/null || true)"
    if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
      # Owner is gone: break the stale lock and retry at once.
      rm -rf "$lock"
      continue
    fi
    if [ "$i" -ge "$wait_s" ]; then
      echo "checkout-lock: timed out after ${wait_s}s waiting for $lock (owner pid ${owner:-?})" >&2
      return 1
    fi
    i=$((i + 1))
    sleep 1
  done
}

checkout_lock_release() {
  local lock
  lock="$(checkout_lock_path "$1")"
  # Only the owner releases; a stale break by another process is its own path.
  if [ "$(cat "$lock/pid" 2>/dev/null || true)" = "$$" ]; then
    rm -rf "$lock"
  fi
}

with_checkout_lock() {
  local root="$1" wait_s="$2" rc=0
  shift 2
  checkout_lock_acquire "$root" "$wait_s" || return 1
  "$@" || rc=$?
  checkout_lock_release "$root"
  return "$rc"
}
