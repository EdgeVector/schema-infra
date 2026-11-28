# GitHub workflows

GitHub is the gate of record for this repo since 2026-09-30.

## Retirement (2026-11-27)

Tom decided to remove the LastDB Schema Service entirely. lastdb already
removed all callers and the `server_lambda` crate, so this repo can no longer
deploy from current lastdb.

On merge to `main`, `teardown.yml` (after `ci-required` succeeds):

1. Refreshes `SchemaInfraOidcStack` so the deploy roles can empty/delete
   historically `RETAIN`ed data.
2. Tears down **DEV** (`SchemaServiceStack-dev`, us-west-2): empties and deletes
   the catalog S3 bucket, deletes the embeddings table, `cdk destroy`s the
   stack, then verifies each resource is gone.
3. Tears down **PROD** the same way (us-east-1), including API Gateway custom
   domain `schema.folddb.com`.
4. Deletes `SchemaInfraDeployDev` / `SchemaInfraDeployProd`. The account GitHub
   OIDC provider is **kept** (shared with `exemem-infra`).

Deploy, canary, and fold-bump workflows are removed so nothing redeploys.

## Workflows

- `ci-required.yml`: the merge gate. Required status check `ci-required`.
  It runs `.lastgit/ci.sh` (shell/Python syntax and CDK build). It does not
  touch AWS.
- `teardown.yml`: one-shot retirement over GitHub OIDC. Triggers on a
  successful `ci-required` push run on `main`, or `workflow_dispatch` with
  `confirm_teardown=destroy-schema-service`. Do not add an `environment:` key.
- `generated-evidence.yml`: generated-evidence policy check.
