# Schema Service Lambda

Lambda function for the FoldDB Schema Registry service.

## Overview

This Lambda wraps the `schema_service` module from the `fold_db` crate and exposes it as an HTTP API via API Gateway.

## Building

```bash
./build.sh
```

Requires `cargo-lambda` to be installed:

```bash
cargo install cargo-lambda
```

## Environment Variables

| Variable        | Description                            |
| --------------- | -------------------------------------- |
| `SCHEMAS_TABLE` | DynamoDB table name for schema storage |
| `RUST_LOG`      | Logging level (e.g., `info`, `debug`)  |

## API Endpoints

| Method | Path                     | Description                      |
| ------ | ------------------------ | -------------------------------- |
| GET    | `/health`                | Health check                     |
| GET    | `/api/schemas`           | List schema names                |
| GET    | `/api/schemas/available` | Get all schemas with definitions |
| GET    | `/api/schema/{name}`     | Get specific schema              |
| POST   | `/api/schemas`           | Register new schema              |
