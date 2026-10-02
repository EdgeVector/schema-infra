# Signal Sources

## Schema Service Lambda Sentry

The Schema Service Lambda initializes `observability::init_lambda("schema_service", ...)` in the vendored `fold` submodule. `schema-infra` supplies the Sentry runtime configuration at CDK synth/deploy time:

- `OBS_SENTRY_DSN`: optional project DSN. `deploy.sh` reads GitHub Actions variable `OBS_SENTRY_DSN` with `gh variable get` when the process env does not already hold it. The script never prints the value. When the variable is unset, the Lambda DSN stays unset and CloudWatch logging is unchanged. No Sentry project is created here. Do not invent a DSN. Do not put the value in a workflow step env map. Do not add an `environment:` key.
- `OBS_SENTRY_RELEASE`: deploy release tag. `deploy.sh` defaults this to `schema-infra@<git-sha>`.
- `OBS_SENTRY_ENVIRONMENT`: deploy environment tag. `deploy.sh` defaults this to `dev` or `prod`.

Dev deploys target `us-west-2`; prod deploys target `us-east-1`. The GitHub deploy workflow runs `./deploy.sh` through `.lastgit/deploy-pipeline.sh`. The workflow YAML does not interpolate `OBS_SENTRY_DSN`.
