#!/usr/bin/env bash
# LastGit merge gate for schema-infra (not deploy).
set -euo pipefail
cd "$(dirname "$0")/.."
shopt -s nullglob 2>/dev/null || true
echo "== shell syntax =="
for f in ./*.sh .lastgit/*.sh scripts/*.sh; do
  [ -e "$f" ] || continue
  echo "bash -n $f"
  bash -n "$f"
done
echo "== npm/cdk compile =="
npm_version="$(npm --version)"
case "$npm_version" in 10.*|9.*) ;; *) echo "warn: npm $npm_version";; esac
if [ -f cdk/package.json ]; then
  npm --prefix cdk ci --ignore-scripts
  npm --prefix cdk run build
fi
echo "lastgit ci gate PASSED"
