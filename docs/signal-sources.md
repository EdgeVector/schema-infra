# Signal Sources

## Schema Service Lambda Sentry

The Schema Service Lambda initializes `observability::init_lambda("schema_service", ...)` in the vendored `fold` submodule. `schema-infra` supplies fail-closed Sentry configuration in CDK (same pattern as exemem-infra auth/storage):

- `OBS_SENTRY_DSN`: committed public send-only client DSN for the `exemem-backend` Sentry project (`EXEMEM_BACKEND_SENTRY_DSN` in `cdk/lib/environment.ts`). Not loaded from Secrets Manager or a GitHub Actions variable.
- `ENVIRONMENT`: deploy stage (`dev` or `prod`). lastdb observability refuses to start unless this is exactly `dev` or `prod`.

The release SHA is baked at compile time by fold observability `build.rs` (`GITHUB_SHA` / `OBS_SENTRY_RELEASE` / git HEAD). `build.sh` passes that SHA into the AL2023 container.

Dev deploys target `us-west-2`; prod deploys target `us-east-1`.
