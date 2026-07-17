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

## “One box”

Lambda is multi-tenant. **10% weighted alias traffic** is the serverless stand-in for a single canary box. Override with `CANARY_WEIGHT=0.05` etc.

## Env

| Variable | Default | Meaning |
|---|---|---|
| `CANARY_SOAK_HOURS` | `24` | Hours before auto-promote |
| `CANARY_WEIGHT` | `0.1` | Fraction of traffic on new version |
| `LASTGIT_DEPLOY_SKIP_PROD` | unset | Stop after successful dev smoke |
| `DEPLOY_FREEZE` | unset | Skip deploys |
| `SCHEMA_CANARY_ALARM_NAMES` | empty | Optional CW alarms for soak gate |

## Ops

```bash
# Install or repair merge-triggered deploy watcher.
.lastgit/install-deploy-launchd.sh install
.lastgit/install-deploy-launchd.sh status

# Install canary ticker
.lastgit/install-canary-ticker-launchd.sh

# State / logs
ls ~/.lastgit/deploy-schema-infra/
```
