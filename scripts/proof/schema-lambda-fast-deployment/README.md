# Schema Lambda fast deployment — terminal proof harness

North Star: `north-star-schema-lambda-fast-deployment`

Produces `proofs/schema-lambda-fast-deployment.md`. The **first line is
`PASS` only when every North Star completion criterion is represented by
durable, redacted evidence**. The harness fails closed on missing, stale,
secret-bearing, or CodeSha256-inconsistent evidence. It never invents a live
PASS without evidence.

## Operator command

```bash
# From schema-infra repo root. Fails if no evidence is present (default path
# target/schema-lambda-fast-deployment-evidence).
scripts/proof/schema-lambda-fast-deployment/prove.sh

# Against a collected redacted evidence pack:
scripts/proof/schema-lambda-fast-deployment/prove.sh \
  --evidence-dir /path/to/redacted-evidence

# Same via env:
SCHEMA_LAMBDA_PROOF_EVIDENCE=/path/to/redacted-evidence \
  scripts/proof/schema-lambda-fast-deployment/prove.sh

# Optional report path override:
scripts/proof/schema-lambda-fast-deployment/prove.sh \
  --evidence-dir /path/to/redacted-evidence \
  --report proofs/schema-lambda-fast-deployment.md
```

Exit code `0` and report first line `PASS` only when complete. Exit code
non-zero and first line `FAIL` otherwise.

**Do not** pass raw secrets, AWS secret keys, private keys, or resolved
LastSecrets values into the evidence directory. Use digest/hashes, boolean
flags, package counts, and timing integers only. LastSecrets locators
(`lastsecrets://…`) without resolved values are fine if ever needed; raw
material is rejected by the secret scanner.

## Evidence pack layout

All files are JSON under `--evidence-dir`:

| File | Purpose |
|---|---|
| `meta.json` | `schema_version`, `collected_at`, `source`, optional `max_age_hours` |
| `releases.json` | Exactly **10** code-only representative releases with timings + digests |
| `digests.json` | Per-release manifest/CodeSha256 equality (dev == prod) |
| `dependency_budget.json` | Package count, zip size, banned-package absence, embeddings source |
| `path_classification.json` | code-only / infrastructure / no-impact path proofs |
| `coalescing.json` | Three-commit burst → single newest tip deploy |
| `safety_controls.json` | Smoke, canary, alarms, secret handling |
| `rollback.json` | Alias rollback drill &lt; 2 minutes, no rebuild |

### SLO thresholds (enforced)

- p95 `artifact_ready_to_dev_live` &lt; **300s**
- p95 `artifact_ready_to_prod_canary` &lt; **600s**
- p95 warm `merge_to_dev_live` &lt; **900s** (cold measured separately)
- `normal_package_count` &lt; **400**
- `bootstrap_zip_size_bytes` &lt; **15 MiB**
- rollback `duration_sec` &lt; **120**
- each release `builds_for_digest` == **1**
- code-only releases: `cdk_invoked=false`, `rust_compiled=false`

## Fixture mode (CI / harness self-check)

Checked-in fixtures prove fail-closed and PASS paths without live AWS:

```bash
tests/proof/schema-lambda-fast-deployment/test-prove.sh
```

| Fixture | Expected |
|---|---|
| `fixtures/complete` | exit 0, report first line `PASS` |
| `fixtures/incomplete` | exit ≠ 0, first line `FAIL` |
| `fixtures/secret-bearing` | exit ≠ 0, first line `FAIL` |
| `fixtures/digest-mismatch` | exit ≠ 0, first line `FAIL` |
| no evidence dir | exit ≠ 0, first line `FAIL` |

Complete fixtures are **synthetic** and only prove the harness gates. They are
not production evidence. The North Star terminal validation card must run the
operator command against a real redacted evidence pack collected from ten
representative releases.

## Collecting live evidence (outline)

Operators (or a later collector script) assemble redacted JSON from:

1. Deploy telemetry JSONL (`SCHEMA_DEPLOY_TELEMETRY_FILE` /
   `scripts/deploy/telemetry.sh` stage timings)
2. Lambda `CodeSha256` for dev and prod (AWS CLI; never credentials in files)
3. Manifest digests published with the immutable artifact
4. `scripts/deploy/dependency-budget.sh` package counts and zip size
5. Smoke / canary / alarm outcomes (pass/fail only)
6. Coalescing and rollback drills recorded as integers/booleans

Write the pack under a durable path, then run `prove.sh --evidence-dir …`.
Commit or archive the redacted pack + the generated `PASS` report when the
terminal validation card closes the North Star.
