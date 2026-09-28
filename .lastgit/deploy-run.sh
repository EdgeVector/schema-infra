#!/usr/bin/env bash
# Supervise LastGit deploy-pipeline for schema-infra.
#
# lastgit ci watch --context deploy-pipeline fires when LastGit records a
# green ci-required verdict for a new main tip, then runs
# .lastgit/deploy-pipeline.sh. Deliberately NOT a ci-required job itself: a
# production deploy must never be cut off mid-flight by a merge landing on
# top of it.
#
# LastGit-native again as of 2026-09-28 (era-3 reverse migration,
# north-star-lastgit-era-3-primary-migration). Between 2026-09-06 and
# 2026-09-27 this repo's gate of record was Forgejo and this script polled
# Forgejo's REST API instead; that version is still in git history
# (commit d11fdfe and its descendants) if the Forgejo-tracking-checkout
# self-update behavior it added is ever needed again. Not carried forward
# here: it shared a checkout directory and a lock with the canary ticker
# wrapper, both assuming a Forgejo remote, and untangling that pair was out
# of scope for this pass. The canary ticker is unaffected by this change --
# this script no longer touches that shared checkout at all.
set -euo pipefail
REPO="${1:-schema-infra}"
case "$REPO" in
  -*|"")
    echo "deploy-run: invalid repo arg '$REPO' (expected a bare repo name, got a flag or empty string)" >&2
    exit 2
    ;;
esac
CONTEXT="${LASTGIT_DEPLOY_CONTEXT:-deploy-pipeline}"
REF="${LASTGIT_DEPLOY_REF:-refs/heads/main}"
# The staged deploy performs a dev build/deploy, smoke test, prod build/deploy,
# prod smoke, and canary pin. Cold Docker/Rust/CDK runs can exceed three hours.
DEFAULT_TIMEOUT_MS=21600000
TIMEOUT_MS="${LASTGIT_DEPLOY_TIMEOUT_MS:-$DEFAULT_TIMEOUT_MS}"
# Production LastGit now lives on the primary Mini socket. Launchd jobs do not
# always inherit the interactive shell discovery env, so pin it here instead of
# falling back to the retired TCP/code-node route.
export LASTGIT_SOCKET="${LASTGIT_SOCKET:-$HOME/.lastdb/data/folddb.sock}"
export LASTGIT_SCHEMA_MAP="${LASTGIT_SCHEMA_MAP:-$HOME/.lastgit/schema-map.json}"
# Deploy-path decision decision-schema-infra-deploy-path-native-x86-pc:
# the Lambda build runs on the native x86_64 builder by default. Set
# SCHEMA_BUILD_REMOTE_HOST="" to force the legacy local QEMU path.
export SCHEMA_BUILD_REMOTE_HOST="${SCHEMA_BUILD_REMOTE_HOST-pc}"
export AWS_PROFILE="${AWS_PROFILE:-default}"
# Older accepted schema-infra commits predate a repository-level Cargo
# build-jobs mitigation. They still have to pass their original staged
# deploy, but parallel rustc spawning under Docker Desktop's x86 QEMU can
# deadlock before a fixed commit reaches the head of this serialized queue.
# CARGO_BUILD_JOBS is cargo's own env-var form of `[build] jobs` in
# config.toml -- it applies to every cargo invocation this process (and
# everything it execs, including the eventual deploy-pipeline.sh build
# step) sees, regardless of which scratch checkout the run happens in.
# Era-3 drift check (2026-09-28): the previous version of this guard wrote
# a config.toml into `lastgit ci watch --scratch-dir`'s checkout, but that
# flag no longer exists on this CLI verb (the node now derives its own
# scratch location) and the checkout path it uses today was not verified
# stable enough to target with a file write. The env var sidesteps the
# question entirely.
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-1}"
# docker + cargo tooling must be on PATH for launchd (minimal default PATH).
# Prefer the installed LastGit CLI so deploy status writes use the same
# HashRange-compatible client path as the primary forge supervisor.
LASTGIT_INSTALL_BIN_DIR="${LASTGIT_INSTALL_BIN_DIR:-$HOME/.local/bin}"
export PATH="${LASTGIT_INSTALL_BIN_DIR}:${HOME}/.cargo/bin:${HOME}/.bun/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"
command -v lastgit >/dev/null || {
  echo "FAIL: installed lastgit missing on PATH; expected ${LASTGIT_INSTALL_BIN_DIR}/lastgit" >&2
  exit 1
}
LOG_DIR="${LASTGIT_DEPLOY_LOG_DIR:-$HOME/.lastgit/deploy-$REPO}"
mkdir -p "$LOG_DIR"
RUNNER_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER_HEAD="$(git -C "$RUNNER_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
echo "deploy-run: repo=$REPO context=$CONTEXT venue=lastgit ref=$REF timeout_ms=$TIMEOUT_MS logs=$LOG_DIR runner_root=$RUNNER_ROOT runner_head=$RUNNER_HEAD"
WATCH_PID=""

stop() {
  [ -n "$WATCH_PID" ] && kill "$WATCH_PID" 2>/dev/null || true
}
trap 'stop; exit 0' INT TERM
start_watch() {
  # --scratch-dir was removed from this CLI verb since this script was last
  # used (era-3 drift check, 2026-09-28): the node now derives its own
  # scratch/pack-cas location (LASTGIT_PACK_CAS_DIR, else <node dir>, else
  # TMPDIR) rather than taking a caller-supplied path. Passing it now would
  # be an unrecognized flag.
  lastgit ci watch --repo "$REPO" --context "$CONTEXT" --ref "$REF" \
    --timeout-ms "$TIMEOUT_MS" --max-concurrency 1 \
    --state-file "$LOG_DIR/deploy.cursor" \
    >>"$LOG_DIR/deploy.log" 2>&1 &
  WATCH_PID=$!
  echo "pid=$WATCH_PID"
}
start_watch
while true; do
  watch_status=0
  wait "$WATCH_PID" || watch_status=$?
  echo "deploy-run: watch pid=$WATCH_PID exited status=$watch_status; restarting"
  start_watch
done
