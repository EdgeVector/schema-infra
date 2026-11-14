# Canonical vocabulary release phase

`phase` (`dev` or `prod`) is read by `scripts/deploy/canonical-vocabulary-phase.sh` to gate production traffic:

- `dev`: staged deploys run and smoke-check `dev` only, holding `prod` deployments and canary promotions until a reviewed source change flips `phase` back to `prod`.
- `prod`: normal staged delivery (`dev` deploy + smoke, then `prod` 5% canary + 24-hour alarm-gated soak).

The canonical field vocabulary itself is compiled directly into `schema_service_server_lambda` from `builtin_canonical_fields.json` in the `fold/` (`EdgeVector/lastdb`) submodule; the Lambda reads no runtime S3, DynamoDB, or external manifest files.
