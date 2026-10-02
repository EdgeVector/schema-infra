# Signal Sources

## Schema Service Lambda Sentry

The Schema Service Lambda initializes `observability::init_lambda("schema_service", ...)` in the vendored `fold` submodule. `schema-infra` supplies the Sentry runtime configuration at CDK synth/deploy time:

- `OBS_SENTRY_DSN`: optional project DSN. Prod `deploy.sh` reads the GitHub Actions repository variable of this name with `gh variable get` and does not print the value. A failed or unset get leaves the Lambda DSN unset. No Sentry project for schema exists in the org today; do not invent a DSN. When unset or empty, the Lambda keeps CloudWatch logging only.
- `OBS_SENTRY_RELEASE`: deploy release tag. `deploy.sh` defaults this to `schema-infra@<git-sha>`.
- `OBS_SENTRY_ENVIRONMENT`: deploy environment tag. `deploy.sh` defaults this to `dev` or `prod`.

Dev deploys target `us-west-2`; prod deploys target `us-east-1`. The GitHub `deploy.yml` prod job does not put `OBS_SENTRY_DSN` in a step env map and does not add an `environment:` key. The deploy script is the only reader.
