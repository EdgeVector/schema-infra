#!/usr/bin/env bash
# LastGit post-merge schema-infra deploy (dev then prod), context deploy-pipeline.
# Mirrors GH Deploy Pipeline shape without GitHub Actions.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== [schema deploy-pipeline] oid=${LASTGIT_CI_OID:-$(git rev-parse HEAD 2>/dev/null || echo unknown)} =="

if [ "${DEPLOY_FREEZE:-}" = "true" ]; then
  echo "DEPLOY_FREEZE=true — skip"
  exit 0
fi

command -v aws >/dev/null || { echo "FAIL: aws missing" >&2; exit 1; }
aws sts get-caller-identity --query Account --output text >/dev/null
echo "AWS identity OK"

if [ -f .gitmodules ] && [ "${LASTGIT_DEPLOY_SKIP_SUBMODULE:-}" != "1" ]; then
  git submodule update --init --recursive
fi

echo "== DEV: ./deploy.sh dev --yes =="
./deploy.sh dev --yes

if [ "${LASTGIT_DEPLOY_SKIP_PROD:-}" = "1" ]; then
  echo "LASTGIT_DEPLOY_SKIP_PROD — stop after dev"
  exit 0
fi

echo "== PROD: ./deploy.sh prod --yes =="
./deploy.sh prod --yes

echo "lastgit schema deploy-pipeline PASSED"
