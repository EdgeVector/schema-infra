# Schema Infrastructure

Standalone AWS infrastructure for the LastDB Schema Service (`schema.folddb.com`).

## Retirement in progress (2026-11-27)

Tom (CEO) decided on 2026-11-27 to remove the LastDB Schema Service entirely.
`lastdb` #1946 (merge `11748793935057ad90b0f8598693862e4bc18fb5`) already
removed all callers and the `server_lambda` crate, so this repo can no longer
build a deploy from current lastdb.

**This revision replaces the deploy pipeline with a one-shot CI teardown.**
On merge to `main`, `.github/workflows/teardown.yml` destroys DEV then PROD
(including catalog data), verifies each resource is gone, and removes the
schema-infra deploy roles. The shared account GitHub OIDC provider is kept
for `exemem-infra`.

Do not redeploy. See [`.github/workflows/README.md`](.github/workflows/README.md).

## What the stack used to own

- Lambda + API Gateway HTTP API (prod custom domain `schema.folddb.com`)
- Private S3 catalog bucket (`schema-catalog-v2/` and legacy `advisory-catalog-v1/`)
- DynamoDB table `schema-embeddings-<env>-canonical-v2`
- CloudWatch alarms, log groups, Sentry via committed `OBS_SENTRY_DSN`
- IAM roles `SchemaInfraDeployDev` / `SchemaInfraDeployProd`

DNS CNAME for `schema.folddb.com` and the imported ACM certificate were never
CloudFormation-owned in this repo (and are not present in `exemem-infra`).
