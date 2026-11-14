# Staged canary deploy (schema-infra)

## Flow

1. **Merge to `main`** (CI `ci-required` green).
2. **GitHub `deploy.yml`** runs `.lastgit/deploy-pipeline.sh`:
   - Deploy **dev** (`us-west-2`)
   - **Smoke** (`scripts/deploy/smoke-dev.sh`)
   - Deploy **prod** (`us-east-1`)
   - Keep the previous PROD `live` version throughout CDK deployment.
   - Read the numbered candidate's health and vocabulary directly (`scripts/deploy/check-schema-candidate.py`).
   - Pin **5%** of prod `live` alias traffic on the candidate only after those checks.
3. **GitHub `canary-ticker.yml`** (every 15m) waits **`CANARY_SOAK_HOURS` (default 24)**:
   - If soak elapsed and alarms OK → promote to **100%**
   - If alarms ALARM anytime → **rollback** to previous version, then open one GitHub issue labeled `schema-canary-rollback`
   - A host-local routine (`scripts/deploy/file-canary-rollback-cards.sh`) files one kanban card from that issue. The GitHub runner never opens `folddb.sock` and never calls `kanban`.
   - The alias `Description` stores the UTC start time, previous version, new version, and weight. The weighted alias update writes this proof.
   - The GitHub ticker uses the alias `RevisionId` for each promotion or rollback. A concurrent alias change refuses the update.
   - The AWS `get-alias` response has no `LastModified` field.

## Previous version: retained, never substituted

- CDK keeps every Lambda version (`currentVersionOptions.removalPolicy =
  RETAIN` on the function). Before 2026-09-23 CloudFormation deleted the
  version the old template owned at the end of each deploy, which removed the
  pre-deploy live version.
- The canary always retains the version that `live` served before the deploy.
  CDK receives that observed version through `schemaProdLiveVersion` and keeps the alias there.
  `SchemaServiceCandidateVersion` identifies the separately published candidate.
- A missing previous version or failed candidate read refuses the canary.
  No fallback moves all traffic to the candidate, even when its code checksum matches.
- The production deploy job and ticker serialize public alias changes.
  Promotion uses the observed alias revision.
- The canonical vocabulary DEV phase refuses a new PROD canary or promotion.
  An alarm rollback remains available.

## “One box”

Lambda is multi-tenant. **5% weighted alias traffic** is the live canary. Override with `CANARY_WEIGHT`.

## Env

| Variable | Default | Meaning |
|---|---|---|
| `CANARY_SOAK_HOURS` | `24` | Hours before auto-promote |
| `CANARY_WEIGHT` | `0.05` | Fraction of live traffic on the new version |
| `LASTGIT_DEPLOY_SKIP_PROD` | unset | Stop after successful dev smoke |
| `DEPLOY_FREEZE` | unset | Skip deploys |
| `SCHEMA_CANARY_ALARM_NAMES` | `schema-service-lambda-errors-prod schema-service-http-5xx-prod` | Prod soak alarms (Lambda `Errors` + HTTP API `5xx`). Unset or empty still uses this pair — never a time-only gate. |
| `SCHEMA_CANARY_OPEN_ISSUE` | unset (`0`) | Set to `1` on the GitHub ticker so an abort opens one `schema-canary-rollback` issue. |

An idle `live` alias (empty `AdditionalVersionWeights`) exits 0 even before a first CDK deploy creates new alarms. Whenever an active canary (`unproven`, `soaking`, or `due`) is present, a missing named alarm fails the tick and leaves the alias in place. Missing or mismatched clock proof fails a healthy tick and prevents promotion. An ALARM still rolls back a valid weighted alias without clock proof. A weight map that is not one key at 0.05 fails the tick and leaves the alias in place. A deleted live `FunctionVersion` fails the tick and leaves the alias in place. Rollback writes that `FunctionVersion` and clears the weight map. The issue body has four labeled lines: `alarm`, `function`, `old`, `new`.

Install the host-local card filer on a machine that can open the LastDB socket:

```bash
scripts/deploy/install-canary-rollback-card-launchd.sh install
scripts/deploy/install-canary-rollback-card-launchd.sh status
```

## Adopt an existing canary without clock proof

Use the exact pin time from the successful deploy log. Check the function,
previous version, new version, and weight against the live alias. Do not use
the version publish time or an estimated time. The adoption request keeps the
version pair and weight, then adds the clock proof. Its revision check refuses
a concurrent alias change. A description over 256 bytes refuses the request.
The helper preserves the existing free text before its proof marker.

For deploy run `37995202108`, the pin log records version `36`, canary `41`,
weight `0.05`, and pin completion time `2026-10-09T22:01:43Z`. The live read on October 9
confirms that pair. Recheck the live alias and the deploy log before adoption.

```bash
run_dir="$(mktemp -d "${TMPDIR:-/tmp}/schema-canary-adopt.XXXXXX")"
fn=SchemaServiceStack-prod-SchemaServiceFnDF75D4BE-58KcDYig68xw
aws lambda get-alias --function-name "$fn" --name live --region us-east-1 \
  --output json > "$run_dir/alias.json"
python3 scripts/deploy/canary-alias-state.py adopt --function-name "$fn" \
  --old 36 --new 41 --weight 0.05 --started-at 2026-10-09T22:01:43Z \
  < "$run_dir/alias.json" > "$run_dir/request.json"
# Review request.json and the deploy evidence before this shared alias write.
aws lambda update-alias --region us-east-1 \
  --cli-input-json "file://$run_dir/request.json"
```

This procedure needs a separate action review. The code change does not adopt
the existing canary or move the live alias.
