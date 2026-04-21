# Schema Infrastructure

Standalone infrastructure for the FoldDB Schema Service (`schema.folddb.com`).

## Overview

This project contains everything needed to deploy the global schema registry for FoldDB:

- **Lambda Function**: Rust-based schema service with fastembed semantic search
- **S3 Bucket**: Schema blob persistence (one JSON object per schema)
- **API Gateway**: HTTP API with CORS and custom domain support
- **Frontend**: Web UI for browsing schemas

## Architecture

The schema service runs as a single Lambda function with two storage layers:

1. **S3 blob persistence** — each schema stored as `schemas/<name>.json` in an S3 bucket. Replaced the earlier Sled-on-/tmp approach, which was unreliable across cold starts. S3 gives durable, consistent storage with no /tmp size limits.
2. **fastembed Lambda Layer** — a pre-built layer bundles the fastembed model binary so the Lambda doesn't download it on every cold start. Cold start stays under 2s even with the embedding model loaded.

Lambda configuration:
- **Timeout**: 300 seconds (5 minutes) — required for fastembed model loading on first cold start
- **Memory**: 512 MB — required for embedding model inference

## Builtin Canonical Fields

On cold start the Lambda calls `seed_canonical_fields()` to pre-populate ~150 curated canonical fields (e.g., `user_email`, `photo_caption`, `gps_latitude`, `document_title`). Each field has a hardcoded description, data classification, and interest category. These are the shared vocabulary that enables schema deduplication and similarity across different FoldDB nodes.

Canonical fields are used by:
- Schema similarity detection (same semantic field → high similarity score)
- Schema expansion (safely add new fields without breaking existing data)
- Data browser field labeling

## Structure

```
schema-infra/
├── cdk/                    # CDK infrastructure (TypeScript)
│   ├── bin/               # CDK app entry point
│   ├── lib/               # Stack definitions
│   └── package.json       # CDK dependencies
├── schema_service/        # Lambda handler source (submodule → EdgeVector/schema_service)
├── frontend/              # Schema registry web UI
├── build.sh              # Build Lambda zip + fastembed Layer
└── deploy.sh             # Deploy infrastructure
```

Lambda handler source now lives in the [`EdgeVector/schema_service`](https://github.com/EdgeVector/schema_service) repo, vendored here as a submodule at `schema_service/`. `build.sh` runs `cargo lambda build -p schema_service_server_lambda` inside the submodule and emits the deployable zip plus a fastembed Layer asset at `target/fastembed_layer/`.

## Quick Start

### Prerequisites

- Node.js 18+
- Rust (for Lambda build)
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

### Custom Domain

To enable the `schema.folddb.com` custom domain:

1. Create an ACM certificate for `schema.folddb.com` in us-east-1
2. Set the environment variable:
   ```bash
   export SCHEMA_DOMAIN_CERT_ARN="arn:aws:acm:us-east-1:..."
   ```
3. Deploy with `./deploy.sh prod`
4. Add a CNAME record pointing `schema.folddb.com` to the API Gateway domain

## Frontend

The frontend is a static site in `frontend/`. To serve locally:

```bash
cd frontend
python3 -m http.server 8080
```

Deploy to Vercel or another static hosting service.

## API Endpoints

The Lambda serves the full `/v1/*` surface — 19 endpoints covering
schemas, views, transforms, and system. See the canonical list in
[`schema_service/README.md`](https://github.com/EdgeVector/schema_service/blob/main/README.md#http-surface-v1)
or the machine-readable spec at
[`schema_service/openapi.yaml`](https://github.com/EdgeVector/schema_service/blob/main/openapi.yaml).

A few representative routes:

| Method | Path                         | Description                              |
| ------ | ---------------------------- | ---------------------------------------- |
| GET    | `/v1/health`                 | Health check                             |
| GET    | `/v1/schemas`                | List schema names                        |
| GET    | `/v1/schemas/available`      | Get all schemas with definitions         |
| GET    | `/v1/schema/{name}`          | Get a specific schema                    |
| POST   | `/v1/schemas`                | Register / propose a schema              |
| POST   | `/v1/schemas/batch-check-reuse` | Batch reuse-check for proposed schemas |
| GET    | `/v1/views`                  | List view names                          |
| GET    | `/v1/transforms`             | List transform records                   |

## Environment Variables

| Variable | Description |
|----------|-------------|
| `SCHEMAS_BUCKET` | S3 bucket name for schema blob storage |
| `FASTEMBED_CACHE_DIR` | Path to pre-extracted fastembed model (provided by Lambda Layer) |

## Storage Backend

Schemas are stored in S3 as individual JSON blobs:

```
s3://<SCHEMAS_BUCKET>/schemas/<schema_name>.json
```

The `ExternalSchemaPersistence` trait allows plugging in alternative backends. The Lambda uses `S3SchemaPersistence`; the dev binary in [`schema_service/crates/server_http/`](https://github.com/EdgeVector/schema_service/tree/main/crates/server_http) uses `SledSchemaPersistence` (default port 9102, for local development).

## fastembed Lambda Layer

The fastembed model is bundled as a Lambda Layer (`fastembed-model-layer`) and mounted at `/opt/fastembed/`. The Lambda reads `FASTEMBED_CACHE_DIR=/opt/fastembed` so it never downloads the model at runtime. The layer is published once and referenced by ARN in the CDK stack.

## License

MIT / Apache 2.0
