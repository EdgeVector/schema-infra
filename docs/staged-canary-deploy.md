# Staged canary deploy (schema-infra)

## Flow

1. **Merge to LastGit `main`** (CI `ci-required` green).
2. **Deploy watcher** runs `.lastgit/deploy-pipeline.sh`:
   - Deploy **dev** (`us-west-2`)
   - **Smoke** (`scripts/deploy/smoke-dev.sh`)
   - Deploy **prod** (`us-east-1`)
   - Pin **~10%** of prod `live` alias traffic on the new version (canary)
3. **Canary ticker** (every 15m) waits **`CANARY_SOAK_HOURS` (default 24)**:
   - If soak elapsed and alarms OK → promote to **100%**
   - If alarms ALARM anytime → **rollback** to previous version

## Previous version: retained, never substituted

- CDK keeps every Lambda version (`currentVersionOptions.removalPolicy =
  RETAIN` on the function). Before 2026-09-23 CloudFormation deleted the
  version the old template owned at the end of each deploy, which removed the
  pre-deploy live version.
- The canary primary is always the version that `live` served before the
  deploy. If that version is gone, `set_canary_weights` returns 2 and does
  not touch the alias (fail closed): live stays 100% on the new version, no
  soak state is written, a `canary_refused` telemetry row and a Situations
  notice are emitted, and the pipeline exits non-zero. It never picks another
  (older) version. Exception: when the new version has the same CodeSha256 as
  the deleted one, nothing changed, so the pipeline logs it and passes.
- The first deploy after the RETAIN change still deletes the version that the
  previous template owned (CloudFormation applies the old DeletionPolicy).

## “One box”

Lambda is multi-tenant. **10% weighted alias traffic** is the serverless stand-in for a single canary box. Override with `CANARY_WEIGHT=0.05` etc.

## Env

| Variable | Default | Meaning |
|---|---|---|
| `CANARY_SOAK_HOURS` | `24` | Hours before auto-promote |
| `CANARY_WEIGHT` | `0.1` | Fraction of traffic on new version |
| `LASTGIT_DEPLOY_SKIP_PROD` | unset | Stop after successful dev smoke |
| `DEPLOY_FREEZE` | unset | Skip deploys |
| `SCHEMA_CANARY_ALARM_NAMES` | `schema-mutation-gate-hourly-quota-prod schema-mutation-gate-internal-error-prod` | Prod soak alarms. Unset or empty still uses this pair — never a time-only gate. |

## R2-backed Schema Store

By default, CDK creates an AWS S3 bucket for `SCHEMA_STORE_BUCKET`. To deploy the
Schema Service Lambda against a Cloudflare R2/S3-compatible registry store, set
the full deploy-time config together before running `deploy.sh` or the LastGit
deploy watcher:

| Variable | Meaning |
|---|---|
| `SCHEMA_STORE_R2_DEPLOY_BUCKET` | R2 bucket name passed to `SCHEMA_STORE_BUCKET` |
| `SCHEMA_STORE_R2_DEPLOY_ENDPOINT_URL` | R2 S3 API endpoint passed to `SCHEMA_STORE_ENDPOINT_URL` |
| `SCHEMA_STORE_R2_ACCESS_KEY_ID_SECRET_NAME` | AWS Secrets Manager secret name whose value is the R2 access key id |
| `SCHEMA_STORE_R2_SECRET_ACCESS_KEY_SECRET_NAME` | AWS Secrets Manager secret name whose value is the R2 secret access key |
| `SCHEMA_STORE_R2_REGION` | Optional region, defaults to `auto` |

Do not export raw R2 key values into the deploy environment. CDK emits Lambda
environment values for the two credential variables as CloudFormation dynamic
references to Secrets Manager.

## Ops

```bash
# Install or repair merge-triggered deploy watcher.
.lastgit/install-deploy-launchd.sh install
.lastgit/install-deploy-launchd.sh status

# Install or repair canary ticker, then verify the loaded script/log.
.lastgit/install-canary-ticker-launchd.sh install
.lastgit/install-canary-ticker-launchd.sh status

# State / logs
ls ~/.lastgit/deploy-schema-infra/
```
