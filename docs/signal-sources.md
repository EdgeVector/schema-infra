# Signal Sources

## Schema Service Lambda Sentry

The Schema Service Lambda initializes `observability::init_lambda("schema_service", ...)` in the vendored `fold` submodule. `schema-infra` supplies the Sentry runtime configuration at CDK synth/deploy time:

- `OBS_SENTRY_DSN`: optional project DSN. When unset or empty, the Lambda keeps CloudWatch logging only.
- `OBS_SENTRY_RELEASE`: deploy release tag. `deploy.sh` defaults this to `schema-infra@<git-sha>`.
- `OBS_SENTRY_ENVIRONMENT`: deploy environment tag. `deploy.sh` defaults this to `dev` or `prod`.

Dev deploys target `us-west-2`; prod deploys target `us-east-1`. The LastGit deploy pipeline runs `./deploy.sh dev --yes` and then `./deploy.sh prod --yes`, so both environments receive the same Sentry variable set when `OBS_SENTRY_DSN` is present in the deploy runner environment.
