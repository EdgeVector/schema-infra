#!/usr/bin/env bash
# Terminal proof harness for north-star-schema-lambda-fast-deployment.
#
# Fail closed without complete redacted evidence. Writes
# proofs/schema-lambda-fast-deployment.md with first line PASS only when every
# North Star criterion has durable evidence.
#
# Operator commands (no raw secrets):
#   scripts/proof/schema-lambda-fast-deployment/prove.sh
#   scripts/proof/schema-lambda-fast-deployment/prove.sh --evidence-dir /path/to/evidence
#   SCHEMA_LAMBDA_PROOF_EVIDENCE=/path/to/evidence \
#     scripts/proof/schema-lambda-fast-deployment/prove.sh
#
# Fixture self-check:
#   tests/proof/schema-lambda-fast-deployment/test-prove.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
exec python3 "$ROOT/scripts/proof/schema-lambda-fast-deployment/prove.py" \
  --repo-root "$ROOT" \
  "$@"
