# Signal Sources

## Schema Service Lambda Sentry

The Schema Service Lambda initializes `observability::init_lambda("schema_service", ...)` in the vendored `fold` submodule. `schema-infra` supplies fail-closed Sentry configuration in CDK (same pattern as exemem-infra auth/storage):

- `OBS_SENTRY_DSN`: committed public send-only client DSN for the `exemem-backend` Sentry project (`EXEMEM_BACKEND_SENTRY_DSN` in `cdk/lib/environment.ts`). Not loaded from Secrets Manager or a GitHub Actions variable.
- `ENVIRONMENT`: deploy stage (`dev` or `prod`). lastdb observability refuses to start unless this is exactly `dev` or `prod`.

The release SHA is baked at compile time by fold observability `build.rs`. `build.sh` passes the fold pin OID as `GITHUB_SHA` into the AL2023 container so the baked release matches the artifact input digest (and therefore any `ensure-artifact.sh` cache hit).

Dev deploys target `us-west-2`; prod deploys target `us-east-1`.
