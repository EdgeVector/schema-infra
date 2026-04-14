//! Schema Service Lambda handler
//!
//! This Lambda function provides the global schema registry for FoldDB.
//! It wraps `fold_db::schema_service::state::SchemaServiceState` as an
//! HTTP API via API Gateway. Supports both schema and view registration
//! endpoints.
//!
//! Storage: Sled-only after fold_db#494 removed DynamoDB. The Lambda
//! expects SCHEMA_DB_PATH to point at a writable directory; production
//! must back this with EFS for persistence across cold starts.

// The `lambda_http::Error` type wraps a boxed error that Clippy's
// result_large_err lint flags. The whole Lambda uses this error
// consistently; rewriting every handler to box-on-return would be
// substantial churn without behavior benefit.
#![allow(clippy::result_large_err)]

#[cfg(not(test))]
use fold_db::schema_service::state::SchemaServiceState;
#[cfg(not(test))]
use fold_db::schema_service::types::{AddViewRequest, SchemaAddOutcome, ViewAddOutcome};

#[cfg(not(test))]
use lambda_http::Request;
#[cfg(not(test))]
use lambda_http::{run, service_fn};
use lambda_http::{Body, Error, Response};
use serde_json::{json, Value};
#[cfg(not(test))]
use std::collections::HashMap;
#[cfg(not(test))]
use std::env;
#[cfg(not(test))]
use std::sync::Arc;
#[cfg(not(test))]
use tokio::sync::OnceCell;
#[cfg(not(test))]
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt, EnvFilter};

// Global singleton for Lambda warm starts
#[cfg(not(test))]
static SCHEMA_STATE: OnceCell<Arc<SchemaServiceState>> = OnceCell::const_new();

/// Build a JSON response with CORS headers
fn json_response(status: u16, body: Value) -> Result<Response<Body>, Error> {
    Response::builder()
        .status(status)
        .header("Content-Type", "application/json")
        .header("Access-Control-Allow-Origin", "*")
        .header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        .header(
            "Access-Control-Allow-Headers",
            "Content-Type, Authorization",
        )
        .body(Body::from(body.to_string()))
        .map_err(|e| Error::from(format!("Failed to build response: {}", e)))
}

/// Resolve a Secrets Manager ARN to its plaintext value and set it as an env var.
/// This lets downstream code (classify.rs) read ANTHROPIC_API_KEY from env as usual.
#[cfg(not(test))]
async fn resolve_secret_to_env(secret_arn: &str, env_var: &str) -> Result<(), Error> {
    let config = aws_config::load_defaults(aws_config::BehaviorVersion::latest()).await;
    let client = aws_sdk_secretsmanager::Client::new(&config);
    let result = client
        .get_secret_value()
        .secret_id(secret_arn)
        .send()
        .await
        .map_err(|e| Error::from(format!("Failed to fetch secret {}: {}", env_var, e)))?;
    let value = result
        .secret_string()
        .ok_or_else(|| Error::from(format!("Secret {} has no string value", env_var)))?;
    env::set_var(env_var, value);
    tracing::info!("Resolved {} from Secrets Manager", env_var);
    Ok(())
}

/// Initialize the schema service state (once per cold start)
#[cfg(not(test))]
async fn get_or_init_state() -> Result<Arc<SchemaServiceState>, Error> {
    // Resolve secrets before entering OnceCell (aws_sdk clients aren't Send)
    if env::var("ANTHROPIC_API_KEY").is_err() {
        if let Ok(arn) = env::var("ANTHROPIC_API_KEY_SECRET_ARN") {
            resolve_secret_to_env(&arn, "ANTHROPIC_API_KEY").await?;
        }
    }

    SCHEMA_STATE
        .get_or_try_init(|| async {
            // The schema service is Sled-only after fold_db#494 removed
            // the DynamoDB backend. SCHEMA_DB_PATH tells this Lambda
            // where to open the Sled directory. For persistent
            // production state the CDK stack MUST mount EFS at this
            // path; otherwise the state is ephemeral per cold start
            // and user-proposed schemas are lost (built-in schemas
            // would still be re-seeded every cold start, but user
            // content would not survive).
            //
            // Default: /mnt/schema (the expected EFS mount point).
            // Override with SCHEMA_DB_PATH=/tmp/schema for ephemeral
            // testing in non-production Lambdas.
            let db_path = env::var("SCHEMA_DB_PATH").unwrap_or_else(|_| "/mnt/schema".to_string());

            tracing::info!(
                "Initializing schema service with Sled storage at: {}",
                db_path
            );

            let state = SchemaServiceState::new(db_path.clone()).map_err(|e| {
                Error::from(format!(
                    "Failed to initialize schema service at '{}': {}. \
                     Ensure SCHEMA_DB_PATH points at a writable directory \
                     (production: EFS-backed; dev: any local path).",
                    db_path, e
                ))
            })?;

            // Seed the twelve Phase 1 built-in fingerprint schemas.
            // These are system primitives (Fingerprint, Mention,
            // Edge, Identity, IdentityReceipt, Persona, and the three
            // junction + three support schemas). They must exist
            // before any fold_db_node running the fingerprints
            // subsystem can start, because the node fetches them by
            // descriptive name at startup and refuses to boot if any
            // are missing.
            //
            // Idempotent: schemas already present (from a previous
            // cold start, past deploy, or legacy propose-based flows
            // from fold_db_node versions before the schema-service-
            // built-ins migration) are skipped by identity_hash match.
            // Fails loudly on any real error so the Lambda cold-start
            // crashes rather than serving requests against a half-
            // seeded registry.
            fold_db::schema_service::builtin_schemas::seed(&state)
                .await
                .map_err(|e| {
                    Error::from(format!(
                        "Failed to seed Phase 1 built-in schemas: {}. \
                     The Lambda cannot serve fingerprint-subsystem \
                     requests without these.",
                        e
                    ))
                })?;

            tracing::info!(
                "Schema service initialized and built-ins seeded ({} descriptive names)",
                fold_db::schema_service::builtin_schemas::PHASE_1_DESCRIPTIVE_NAMES.len()
            );
            Ok(Arc::new(state))
        })
        .await
        .cloned()
}

/// Get a schema by name — shared handler for both /api/schema/{name} and /api/schemas/{name}
#[cfg(not(test))]
fn get_schema_by_name(
    state: &SchemaServiceState,
    schema_name: &str,
) -> Result<Response<Body>, Error> {
    match state.get_schema_by_name(schema_name) {
        Ok(Some(schema)) => {
            let body = serde_json::to_value(schema)
                .map_err(|e| Error::from(format!("Serialization error: {}", e)))?;
            json_response(200, body)
        }
        Ok(None) => json_response(404, json!({"error": "Schema not found"})),
        Err(e) => json_response(
            500,
            json!({"error": format!("Failed to get schema: {}", e)}),
        ),
    }
}

/// Get a view by name
#[cfg(not(test))]
fn get_view_by_name(state: &SchemaServiceState, view_name: &str) -> Result<Response<Body>, Error> {
    match state.get_view_by_name(view_name) {
        Ok(Some(view)) => {
            let body = serde_json::to_value(view)
                .map_err(|e| Error::from(format!("Serialization error: {}", e)))?;
            json_response(200, body)
        }
        Ok(None) => json_response(404, json!({"error": "View not found"})),
        Err(e) => json_response(500, json!({"error": format!("Failed to get view: {}", e)})),
    }
}

/// Parse the request body as a string
#[cfg(not(test))]
fn parse_body(event: &Request) -> Result<String, Response<Body>> {
    match event.body() {
        Body::Text(s) => Ok(s.clone()),
        Body::Binary(b) => Ok(String::from_utf8_lossy(b).to_string()),
        Body::Empty => Err(json_response(400, json!({"error": "Request body is empty"})).unwrap()),
    }
}

#[cfg(not(test))]
async fn function_handler(event: Request) -> Result<Response<Body>, Error> {
    let state = get_or_init_state().await?;

    let method = event.method().as_str();
    let path = event.uri().path();

    tracing::info!("Request: {} {}", method, path);

    // Route handling based on path
    match (method, path) {
        // Health check
        ("GET", "/health") | ("GET", "/api/health") => json_response(
            200,
            json!({
                "status": "healthy",
                "service": "schema-service"
            }),
        ),

        // ============== Schema Endpoints ==============

        // List schema names
        ("GET", "/api/schemas") => match state.get_schema_names() {
            Ok(schema_names) => json_response(200, json!({ "schemas": schema_names })),
            Err(e) => json_response(
                500,
                json!({"error": format!("Failed to get schema names: {}", e)}),
            ),
        },

        // Get all schemas with definitions
        ("GET", "/api/schemas/available") => match state.get_all_schemas_cached() {
            Ok(schemas) => json_response(200, json!({ "schemas": schemas })),
            Err(e) => json_response(
                500,
                json!({"error": format!("Failed to get schemas: {}", e)}),
            ),
        },

        // Find similar schemas
        (method, path) if method == "GET" && path.starts_with("/api/schemas/similar/") => {
            let schema_name = path.trim_start_matches("/api/schemas/similar/");
            let threshold: f64 = event
                .uri()
                .query()
                .and_then(|q| {
                    q.split('&')
                        .find_map(|param| param.strip_prefix("threshold="))
                        .and_then(|v| v.parse().ok())
                })
                .unwrap_or(0.5);

            if !(0.0..=1.0).contains(&threshold) {
                return json_response(
                    400,
                    json!({"error": "Threshold must be between 0.0 and 1.0"}),
                );
            }

            match state.find_similar_schemas(schema_name, threshold) {
                Ok(response) => {
                    let body = serde_json::to_value(response)
                        .map_err(|e| Error::from(format!("Serialization error: {}", e)))?;
                    json_response(200, body)
                }
                Err(e) => {
                    let error_msg = format!("{}", e);
                    if error_msg.contains("not found") {
                        json_response(
                            404,
                            json!({"error": format!("Schema '{}' not found", schema_name)}),
                        )
                    } else {
                        json_response(
                            500,
                            json!({"error": format!("Failed to find similar schemas: {}", e)}),
                        )
                    }
                }
            }
        }

        // Get specific schema (singular /api/schema/{name} or plural /api/schemas/{name})
        (method, path)
            if method == "GET"
                && (path.starts_with("/api/schema/") || path.starts_with("/api/schemas/")) =>
        {
            let schema_name = path
                .strip_prefix("/api/schemas/")
                .or_else(|| path.strip_prefix("/api/schema/"))
                .unwrap_or("");
            get_schema_by_name(&state, schema_name)
        }

        // Add schema (POST)
        ("POST", "/api/schemas") => {
            let body = match parse_body(&event) {
                Ok(b) => b,
                Err(r) => return Ok(r),
            };

            let request: Value = match serde_json::from_str(&body) {
                Ok(v) => v,
                Err(e) => {
                    return json_response(400, json!({"error": format!("Invalid JSON: {}", e)}));
                }
            };

            // Extract schema and mutation_mappers from request
            let schema = match request.get("schema") {
                Some(s) => match serde_json::from_value(s.clone()) {
                    Ok(schema) => schema,
                    Err(e) => {
                        return json_response(
                            400,
                            json!({"error": format!("Invalid schema: {}", e)}),
                        );
                    }
                },
                None => {
                    return json_response(400, json!({"error": "Missing 'schema' field"}));
                }
            };

            let mutation_mappers = match request.get("mutation_mappers") {
                Some(m) => match serde_json::from_value(m.clone()) {
                    Ok(mappers) => mappers,
                    Err(e) => {
                        tracing::warn!("Failed to parse mutation_mappers, using empty: {}", e);
                        HashMap::new()
                    }
                },
                None => HashMap::new(),
            };

            match state.add_schema(schema, mutation_mappers).await {
                Ok(SchemaAddOutcome::Added(schema, mutation_mappers)) => json_response(
                    201,
                    json!({
                        "schema": schema,
                        "mutation_mappers": mutation_mappers,
                    }),
                ),
                Ok(SchemaAddOutcome::AlreadyExists(schema, mutation_mappers)) => json_response(
                    200,
                    json!({
                        "schema": schema,
                        "mutation_mappers": mutation_mappers,
                    }),
                ),
                Ok(SchemaAddOutcome::Expanded(old_name, schema, mutation_mappers)) => {
                    json_response(
                        201,
                        json!({
                            "schema": schema,
                            "mutation_mappers": mutation_mappers,
                            "replaced_schema": old_name,
                        }),
                    )
                }
                Err(e) => json_response(
                    400,
                    json!({"error": format!("Failed to add schema: {}", e)}),
                ),
            }
        }

        // Reload schemas
        ("POST", "/api/schemas/reload") => match state.load_schemas().await {
            Ok(_) => {
                let count = state.get_schema_count();
                json_response(
                    200,
                    json!({
                        "ok": true,
                        "count": count,
                        "message": format!("Reloaded {} schemas", count)
                    }),
                )
            }
            Err(e) => json_response(500, json!({"error": format!("Failed to reload: {}", e)})),
        },

        // ============== View Endpoints ==============

        // List view names
        ("GET", "/api/views") => match state.get_view_names() {
            Ok(names) => json_response(200, json!({ "views": names })),
            Err(e) => json_response(
                500,
                json!({"error": format!("Failed to get view names: {}", e)}),
            ),
        },

        // Get all views with definitions
        ("GET", "/api/views/available") => match state.get_all_views() {
            Ok(views) => json_response(200, json!({ "views": views })),
            Err(e) => json_response(500, json!({"error": format!("Failed to get views: {}", e)})),
        },

        // Get specific view
        (method, path) if method == "GET" && path.starts_with("/api/view/") => {
            let view_name = path.trim_start_matches("/api/view/");
            get_view_by_name(&state, view_name)
        }

        // TODO: Transform Registry — when a view with a WASM transform is registered,
        // run automated classification downgrading tests. Compare the output schema's
        // field classifications against the input schema's classifications to determine
        // if the transform reduces data sensitivity (e.g., PII → aggregated stats).
        // See docs/classification_downgrading_white_paper.pdf for the formal model.
        // This enables transforms to be auto-approved when they provably downgrade
        // classification, and flagged for manual review when they don't.

        // Register a view (POST)
        ("POST", "/api/views") => {
            let body = match parse_body(&event) {
                Ok(b) => b,
                Err(r) => return Ok(r),
            };

            let request: AddViewRequest = match serde_json::from_str(&body) {
                Ok(r) => r,
                Err(e) => {
                    return json_response(
                        400,
                        json!({"error": format!("Invalid view request: {}", e)}),
                    );
                }
            };

            let view_name = request.name.clone();
            match state.add_view(request).await {
                Ok(ViewAddOutcome::Added(view, schema)) => json_response(
                    201,
                    json!({
                        "view": view,
                        "output_schema": schema,
                    }),
                ),
                Ok(ViewAddOutcome::AddedWithExistingSchema(view, schema)) => json_response(
                    200,
                    json!({
                        "view": view,
                        "output_schema": schema,
                    }),
                ),
                Ok(ViewAddOutcome::Expanded(view, schema, old_name)) => json_response(
                    201,
                    json!({
                        "view": view,
                        "output_schema": schema,
                        "replaced_schema": old_name,
                    }),
                ),
                Err(e) => {
                    tracing::error!("Failed to register view '{}': {}", view_name, e);
                    json_response(
                        400,
                        json!({"error": format!("Failed to register view: {}", e)}),
                    )
                }
            }
        }

        // ============== Root & Fallback ==============

        // Root endpoint
        ("GET", "/") | ("POST", "/") => json_response(
            200,
            json!({
                "service": "FoldDB Schema & View Registry",
                "version": "2.0.0",
                "endpoints": {
                    "GET /health": "Health check",
                    "GET /api/schemas": "List schema names",
                    "GET /api/schemas/available": "Get all schemas with definitions",
                    "GET /api/schemas/similar/{name}?threshold=0.5": "Find similar schemas",
                    "GET /api/schema/{name}": "Get specific schema",
                    "POST /api/schemas": "Add new schema",
                    "POST /api/schemas/reload": "Reload schemas from storage",
                    "GET /api/views": "List view names",
                    "GET /api/views/available": "Get all views with definitions",
                    "GET /api/view/{name}": "Get specific view",
                    "POST /api/views": "Register a new view"
                }
            }),
        ),

        // Not found
        _ => json_response(
            404,
            json!({"error": format!("Not found: {} {}", method, path)}),
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_json_response_success() {
        let resp = json_response(200, json!({"ok": true})).unwrap();
        assert_eq!(resp.status(), 200);
        assert_eq!(
            resp.headers().get("Content-Type").unwrap(),
            "application/json"
        );
        let body = match resp.body() {
            Body::Text(s) => s.clone(),
            _ => panic!("Expected text body"),
        };
        assert!(body.contains("\"ok\":true") || body.contains("\"ok\": true"));
    }

    #[test]
    fn test_json_response_error_status() {
        let resp = json_response(404, json!({"error": "not found"})).unwrap();
        assert_eq!(resp.status(), 404);
        let body = match resp.body() {
            Body::Text(s) => s.clone(),
            _ => panic!("Expected text body"),
        };
        assert!(body.contains("not found"));
    }

    #[test]
    fn test_json_response_includes_cors_headers() {
        let resp = json_response(500, json!({"error": "fail"})).unwrap();
        assert_eq!(
            resp.headers().get("Access-Control-Allow-Origin").unwrap(),
            "*"
        );
        assert_eq!(
            resp.headers().get("Access-Control-Allow-Methods").unwrap(),
            "GET, POST, OPTIONS"
        );
        assert_eq!(
            resp.headers().get("Access-Control-Allow-Headers").unwrap(),
            "Content-Type, Authorization"
        );
    }

    #[test]
    fn test_json_response_400_bad_request() {
        let resp = json_response(400, json!({"error": "Invalid JSON: unexpected EOF"})).unwrap();
        assert_eq!(resp.status(), 400);
        let body = match resp.body() {
            Body::Text(s) => s.clone(),
            _ => panic!("Expected text body"),
        };
        assert!(body.contains("Invalid JSON"));
    }
}

#[cfg(not(test))]
#[tokio::main]
async fn main() -> Result<(), Error> {
    // Initialize tracing with JSON formatting for CloudWatch
    tracing_subscriber::registry()
        .with(EnvFilter::from_default_env())
        .with(tracing_subscriber::fmt::layer().json())
        .init();

    tracing::info!("Schema service Lambda starting...");

    run(service_fn(function_handler)).await
}
