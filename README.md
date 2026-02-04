# Schema Infrastructure

Standalone infrastructure for the FoldDB Schema Service (`schema.folddb.com`).

## Overview

This project contains everything needed to deploy the global schema registry for FoldDB:

- **Lambda Function**: Rust-based schema service
- **DynamoDB Table**: Schema storage
- **API Gateway**: HTTP API with CORS and custom domain support
- **Frontend**: Web UI for browsing schemas

## Structure

```
schema-infra/
├── cdk/                    # CDK infrastructure
│   ├── bin/               # CDK app entry point
│   ├── lib/               # Stack definitions
│   └── package.json       # CDK dependencies
├── lambdas/
│   └── schema_service/    # Schema service Lambda
├── frontend/              # Schema registry web UI
├── build.sh              # Build Lambda
└── deploy.sh             # Deploy infrastructure
```

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

# Deploy to production
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

| Method | Path                     | Description                      |
| ------ | ------------------------ | -------------------------------- |
| GET    | `/health`                | Health check                     |
| GET    | `/api/schemas`           | List schema names                |
| GET    | `/api/schemas/available` | Get all schemas with definitions |
| GET    | `/api/schema/{name}`     | Get specific schema              |
| POST   | `/api/schemas`           | Register new schema              |

## License

MIT / Apache 2.0
