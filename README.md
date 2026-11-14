# Schema Infrastructure

Standalone infrastructure for the LastDB Schema Service (`schema.folddb.com`).

## Repository Venue

`schema-infra` is canonical on GitHub (`EdgeVector/schema-infra`) since 2026-09-30.
Pull requests, the `ci-required` check, and merges use GitHub. The old LastGit
and Forgejo copies are frozen. A Schema Service change in `EdgeVector/lastdb`
deploys on merge: an auto-merged PR moves the `fold` pin, then `deploy.yml`
deploys DEV, smokes DEV, and follows the PROD canary rules. See
[`.github/workflows/README.md`](.github/workflows/README.md).

## Overview

This project deploys the stateless advisory Schema Service for LastDB:

- **Lambda Function**: Rust-based pure-CPU deterministic advisory service backed by compile-time `builtin_canonical_fields.json` (no runtime S3, DynamoDB, Secrets Manager, or ONNX/fastembed Layer dependencies)
- **API Gateway**: HTTP API (`GET`, `POST`, `OPTIONS`) with route rate limiting, CORS, and custom domain (`schema.folddb.com`)
- **CloudWatch Alarms**: Per-environment alarms on Lambda `Errors` (`schema-service-lambda-errors-<env>`) and HTTP API `5xx` (`schema-service-http-5xx-<env>`) gating staged canary promotion
- **Retained Historical Stores**: `SchemaBucket` (S3) and `AtomicVocabularyEmbeddingsTable` (DynamoDB) remain retained in CloudFormation with no Lambda grants

## Release planes

Every merge to `main` is classified by `scripts/deploy/classify-change.sh`
(design: design-schema-lambda-fast-deployment) and takes one of three paths
through `.lastgit/deploy-pipeline.sh`:

- **code-only** — the fold submodule pin changed, CDK inputs did not. The
  prebuilt, digest-verified artifact is published via the AWS CLI
  (`update-function-code` → CodeSha256 gate → `publish-version` → `live`
  alias / weighted prod canary). No CDK, no compilation in the release path.
- **infrastructure** — CDK or deploy machinery inputs changed. CDK deploys
  referencing the prebuilt artifact; Rust is never compiled inside the CDK
  path.
- **no-impact** — docs/proofs/frontend only. The deploy is skipped with an
  explicit successful reason.

Artifacts are built once per input digest into a content-addressed store with a
secret-free manifest; pending main events coalesce to the newest eligible
tip before any expensive work. Evidence for the North Star terminal proof
is collected by `scripts/proof/schema-lambda-fast-deployment/collect.py`.

### Build host

`build.sh` runs the Lambda build in an Amazon Linux 2023 container in Docker
(`--platform linux/amd64`). CI builds natively on the hosted x86_64 runner.
A local Apple Silicon build runs under QEMU and can wedge. Production deploys
go through `deploy.yml`.

## Architecture

`schema_service_server_lambda` runs as a single stateless Lambda function behind an API Gateway v2 HTTP API (`live` alias):

1. **Compile-time vocabulary** — canonical fields and deterministic schema advice come from `builtin_canonical_fields.json` compiled directly into the Rust binary (`schema_service_core`).
2. **Zero external runtime state** — the request path makes no calls to S3, R2, DynamoDB, Secrets Manager, or external model endpoints, and attaches no Lambda Layers.
3. **Real canary health gates** — production deploys route 5% of `live` alias traffic to the new numbered version and soak for 24 hours gated by `schema-service-lambda-errors-prod` and `schema-service-http-5xx-prod`.

## Structure

```
schema-infra/
├── cdk/                    # CDK infrastructure (TypeScript)
│   ├── bin/               # CDK app entry point
│   ├── lib/               # Stack definitions
│   └── package.json       # CDK dependencies
├── fold/                  # Lambda handler source (submodule → EdgeVector/lastdb monorepo)
├── build.sh              # Build Lambda zip in AL2023 container
└── deploy.sh             # Deploy infrastructure
```

Lambda handler source lives in the [`EdgeVector/lastdb`](https://github.com/EdgeVector/lastdb) monorepo, vendored here as a submodule at `fold/`. `build.sh` runs `cargo lambda build -p schema_service_server_lambda --locked` inside the AL2023 builder container and extracts the deployable zip to `fold/target/lambda/server_lambda-extracted/`.

## Quick Start

### Prerequisites

- Node.js 18+
- Docker (for AL2023 Lambda container build)
- AWS CLI configured
- CDK bootstrapped (`npx cdk bootstrap`)

### Build

```bash
./build.sh
```

### Deploy

```bash
# Deploy to dev
./deploy.sh dev

# Deploy to production (schema.folddb.com)
./deploy.sh prod
```

### Smoke check

```bash
# Against dev (default) or prod:
scripts/deploy/smoke-dev.sh
scripts/deploy/smoke-dev.sh prod
```

### Schema Lambda fast-deployment terminal proof

North Star terminal report for `north-star-schema-lambda-fast-deployment`.
Fail closed without redacted evidence; first line of
`proofs/schema-lambda-fast-deployment.md` is `PASS` only when all criteria
hold (ten-release timings, digests, dependency budget, path classification,
coalescing, smoke/canary/alarms, rollback). No raw secrets in evidence or
report.

```bash
# Operator (against a collected redacted evidence pack):
scripts/proof/schema-lambda-fast-deployment/prove.sh \
  --evidence-dir /path/to/redacted-evidence
```

Details: [`scripts/proof/schema-lambda-fast-deployment/README.md`](scripts/proof/schema-lambda-fast-deployment/README.md).

### Custom Domain

To enable the `schema.folddb.com` custom domain:

1. Create an ACM certificate for `schema.folddb.com` in us-east-1
2. Deploy with `./deploy.sh prod`
3. Add a CNAME record pointing `schema.folddb.com` to the API Gateway domain

## API Endpoints

The Lambda serves the read-only advisory surface (`/` and `/health` plus `/v1/*`
health, canonical vocabulary, and schema advice):

| Method     | Path                    | Description                                                       |
| ---------- | ----------------------- | ----------------------------------------------------------------- |
| GET / POST | `/`                     | Service metadata and live endpoint index                          |
| GET        | `/health`               | Health check (unversioned alias)                                  |
| GET        | `/v1/health`            | Health check                                                      |
| GET        | `/v1/fields/vocabulary` | Read the standard canonical vocabulary                            |
| POST       | `/v1/advice/schema`     | Advice for one draft schema declaration (read-only, non-blocking) |

## Environment Variables

| Variable | Description |
|----------|-------------|
| `RUST_LOG` | Tracing log filter (`info`) |
| `ENVIRONMENT` | Deployment environment name (`dev` or `prod`) |
| `OBS_SENTRY_DSN` | Optional Sentry DSN. Prod `deploy.sh` reads the GitHub Actions variable of this name with `gh variable get` and never prints it; empty or a failed get disables the Sentry sink |
| `OBS_SENTRY_RELEASE` | Sentry release tag; `deploy.sh` defaults this to `schema-infra@<git-sha>` |
| `OBS_SENTRY_ENVIRONMENT` | Sentry environment tag; `deploy.sh` defaults this to the deploy target (`dev` or `prod`) |

The local HTTP binary is [`schema_service/crates/server_http`](https://github.com/EdgeVector/lastdb/tree/main/schema_service/crates/server_http) in `EdgeVector/lastdb`.

## License

MIT / Apache 2.0
