#!/usr/bin/env bash
# Supervise LastGit deploy-pipeline for schema-infra.
set -euo pipefail
REPO="${1:-schema-infra}"
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
echo "deploy-run: repo=$REPO context=$CONTEXT ref=$REF timeout_ms=$TIMEOUT_MS logs=$LOG_DIR runner_root=$RUNNER_ROOT runner_head=$RUNNER_HEAD"
WATCH_PID=""
stop() { [ -n "$WATCH_PID" ] && kill "$WATCH_PID" 2>/dev/null || true; }
trap 'stop; exit 0' INT TERM
start_watch() {
  lastgit ci watch --repo "$REPO" --context "$CONTEXT" --ref "$REF" \
    --timeout-ms "$TIMEOUT_MS" --max-concurrency 1 \
    --state-file "$LOG_DIR/deploy.cursor" --scratch-dir "$LOG_DIR/scratch" \
    >>"$LOG_DIR/deploy.log" 2>&1 &
  WATCH_PID=$!
}
start_watch
echo "pid=$WATCH_PID"
while true; do
  sleep 5
  kill -0 "$WATCH_PID" 2>/dev/null || { sleep 2; start_watch; }
done
