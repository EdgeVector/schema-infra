# schema-infra (retired)

This repository held the AWS CDK deploy for the LastDB Schema Service
(`schema.folddb.com`).

**Retired on 2026-11-27** by Tom (CEO). The Schema Service was removed entirely:
`lastdb` #1946 (merge `11748793935057ad90b0f8598693862e4bc18fb5`) deleted all
callers and the `server_lambda` crate, so this repo could no longer build or
deploy from current lastdb. Schemas now live on each database's signed log;
install uses definitions from the app's own `lastdb-app.json` at the signed
commit. There is no Schema Service HTTP endpoint.

AWS resources in DEV and PROD (Lambda, API Gateway + `schema.folddb.com` domain
mapping, private catalog S3 bucket and data, DynamoDB embeddings table, alarms,
log groups, and `SchemaInfraDeploy*` roles) were destroyed via CI teardown on
merge of #749 (`8c3bf67ae9946e467c73a5021d266d775d7e1d5e`). Teardown run:
https://github.com/EdgeVector/schema-infra/actions/runs/46088807962

Not deleted (not owned by this stack / shared):

- Imported ACM certificate `18c59c49-1581-48b4-ba6c-402bfd3ac2d6` (us-east-1)
- DNS CNAME for `schema.folddb.com` (not managed in this repo or `exemem-infra`)
- Account GitHub Actions OIDC provider (shared with `exemem-infra`);
  `SchemaInfraOidcStack` retained to hold it

This GitHub repository is not archived by the retirement teardown.
