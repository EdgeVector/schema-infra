#!/usr/bin/env bash
# The deploy watcher and the canary ticker fast-forward one shared checkout.
# Prove: (1) the mkdir lock serializes two concurrent refreshes, (2) a stale
# lock (dead owner pid) is broken, (3) a held lock times out cleanly.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/scripts/deploy/checkout-lock.sh"
HELPER="$ROOT/scripts/deploy/canary-run-root.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/checkout-lock.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# bare origin + a clone one commit behind, with the lock lib in the tree
git init -q --bare --initial-branch=main "$TMP/origin.git"
git init -q --initial-branch=main "$TMP/src"
git -C "$TMP/src" config user.email t@t; git -C "$TMP/src" config user.name t
mkdir -p "$TMP/src/scripts/deploy"
cp "$LIB" "$TMP/src/scripts/deploy/checkout-lock.sh"
echo a >"$TMP/src/a"; git -C "$TMP/src" add -A; git -C "$TMP/src" commit -qm v1
git -C "$TMP/src" remote add origin "$TMP/origin.git"; git -C "$TMP/src" push -q origin main
git clone -q "$TMP/origin.git" "$TMP/clone"
echo b >"$TMP/src/a"; git -C "$TMP/src" commit -qam v2; git -C "$TMP/src" push -q origin main
NEW="$(git -C "$TMP/src" rev-parse HEAD)"

# (1) N concurrent refreshes through the helper must all succeed and land on NEW.
export LASTGIT_DEPLOY_LOG_DIR="$TMP/log"
run_refresh() {
  # shellcheck source=/dev/null
  source "$HELPER"
  canary_refresh_run_root "$TMP/clone" >/dev/null 2>"$TMP/err.$1" || { echo "refresh $1 failed" >>"$TMP/fail"; cat "$TMP/err.$1" >>"$TMP/fail"; }
}
export -f run_refresh 2>/dev/null || true
for i in 1 2 3 4 5 6; do bash -c "$(declare -f run_refresh); HELPER='$HELPER'; TMP='$TMP'; run_refresh $i" & done
wait
if [ -f "$TMP/fail" ]; then echo "concurrent refreshes failed under the lock:" >&2; cat "$TMP/fail" >&2; exit 1; fi
[ "$(git -C "$TMP/clone" rev-parse HEAD)" = "$NEW" ] || { echo "clone not on NEW after concurrent refresh" >&2; exit 1; }
[ ! -d "$TMP/clone/.git/edgevector-checkout.lock" ] || { echo "lock left behind" >&2; exit 1; }

# (2) stale lock: dead owner pid → broken, acquire proceeds
# shellcheck source=/dev/null
source "$LIB"
mkdir "$TMP/clone/.git/edgevector-checkout.lock"; echo 999999 >"$TMP/clone/.git/edgevector-checkout.lock/pid"
checkout_lock_acquire "$TMP/clone" 3 || { echo "stale lock was not broken" >&2; exit 1; }
[ "$(cat "$TMP/clone/.git/edgevector-checkout.lock/pid")" = "$$" ] || { echo "lock not owned after break" >&2; exit 1; }
checkout_lock_release "$TMP/clone"
[ ! -d "$TMP/clone/.git/edgevector-checkout.lock" ] || { echo "release did not remove the lock" >&2; exit 1; }

# (3) live owner holds it → bounded timeout, non-zero, lock untouched
sleep 30 & HOLDER=$!
mkdir "$TMP/clone/.git/edgevector-checkout.lock"; echo "$HOLDER" >"$TMP/clone/.git/edgevector-checkout.lock/pid"
if checkout_lock_acquire "$TMP/clone" 2 2>/dev/null; then echo "acquire succeeded against a live holder" >&2; exit 1; fi
[ "$(cat "$TMP/clone/.git/edgevector-checkout.lock/pid")" = "$HOLDER" ] || { echo "timeout clobbered the live lock" >&2; exit 1; }
kill "$HOLDER" 2>/dev/null || true; rm -rf "$TMP/clone/.git/edgevector-checkout.lock"

# (4) not a checkout → acquire is a no-op success
checkout_lock_acquire "$TMP/not-a-repo" 1

echo "ok checkout-lock"
