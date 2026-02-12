//! Schema Service Lambda handler
//!
//! This Lambda function provides the global schema registry for FoldDB.
//! It exposes the schema_service from fold_db as an HTTP API via API Gateway.

use fold_db::schema_service::server::SchemaServiceState;
use fold_db::storage::{CloudConfig, ExplicitTables};

use lambda_http::{run, service_fn, Body, Error, Request, Response};
use serde_json::{json, Value};
use std::env;
use std::sync::Arc;
use tokio::sync::OnceCell;
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt, EnvFilter};

// Global singleton for Lambda warm starts
static SCHEMA_STATE: OnceCell<Arc<SchemaServiceState>> = OnceCell::const_new();

/// Build a JSON response with CORS headers
fn json_response(status: u16, body: Value) -> Result<Response<Body>, Error> {
    Response::builder()
        .status(status)
        .header("Content-Type", "application/json")
        .header("Access-Control-Allow-Origin", "*")
        .header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        .header("Access-Control-Allow-Headers", "Content-Type, Authorization")
        .body(Body::from(body.to_string()))
        .map_err(|e| Error::from(format!("Failed to build response: {}", e)))
}

/// Initialize the schema service state (once per cold start)
async fn get_or_init_state() -> Result<Arc<SchemaServiceState>, Error> {
    SCHEMA_STATE
        .get_or_try_init(|| async {
            let table_name = env::var("SCHEMAS_TABLE")
                .unwrap_or_else(|_| "SchemasTable".to_string());
            let region = env::var("AWS_REGION")
                .unwrap_or_else(|_| "us-west-2".to_string());

            tracing::info!("Initializing schema service with table: {} in region: {}", table_name, region);

            // Create CloudConfig for the global schema registry
            // Use __system__ as the user_id for global schemas
            let config = CloudConfig {
                region,
                tables: ExplicitTables {
                    schemas: table_name,
                    // Other tables not used by schema service, but required by struct
                    main: String::new(),
                    metadata: String::new(),
                    permissions: String::new(),
                    transforms: String::new(),
                    orchestrator: String::new(),
                    schema_states: String::new(),
                    public_keys: String::new(),
                    transform_queue: String::new(),
                    native_index: String::new(),
                    process: String::new(),
                    logs: String::new(),
                },
                auto_create: true,
                user_id: Some("__system__".to_string()), // Global registry
                file_storage_bucket: None,
            };

            let state = SchemaServiceState::new_with_cloud(config)
                .await
                .map_err(|e| Error::from(format!("Failed to initialize schema service: {}", e)))?;

            tracing::info!("Schema service initialized successfully");
            Ok(Arc::new(state))
        })
        .await
        .cloned()
}

async fn function_handler(event: Request) -> Result<Response<Body>, Error> {
    let state = get_or_init_state().await?;

    let method = event.method().as_str();
    let path = event.uri().path();

    tracing::info!("Request: {} {}", method, path);

    // Route handling based on path
    match (method, path) {
        // Health check
        ("GET", "/health") | ("GET", "/api/health") => {
            json_response(200, json!({
                "status": "healthy",
                "service": "schema-service"
            }))
        }

        // List schema names
        ("GET", "/api/schemas") => {
            match state.get_schema_names() {
                Ok(schema_names) => json_response(200, json!({ "schemas": schema_names })),
                Err(e) => json_response(500, json!({"error": format!("Failed to get schema names: {}", e)})),
            }
        }

        // Get all schemas with definitions
        ("GET", "/api/schemas/available") => {
            match state.get_all_schemas_cached() {
                Ok(schemas) => json_response(200, json!({ "schemas": schemas })),
                Err(e) => json_response(500, json!({"error": format!("Failed to get schemas: {}", e)})),
            }
        }

        // Get specific schema (singular path)
        (method, path) if method == "GET" && path.starts_with("/api/schema/") => {
            let schema_name = path.trim_start_matches("/api/schema/");
            match state.get_schema_by_name(schema_name) {
                Ok(Some(schema)) => {
                    let body = serde_json::to_value(schema)
                        .map_err(|e| Error::from(format!("Serialization error: {}", e)))?;
                    json_response(200, body)
                }
                Ok(None) => json_response(404, json!({"error": "Schema not found"})),
                Err(e) => json_response(500, json!({"error": format!("Failed to get schema: {}", e)})),
            }
        }

        // Get specific schema (plural path variant)
        // Note: /api/schemas/available is matched by the earlier exact arm,
        // so this only matches actual schema name lookups
        (method, path) if method == "GET" && path.starts_with("/api/schemas/") => {
            let schema_name = path.trim_start_matches("/api/schemas/");
            match state.get_schema_by_name(schema_name) {
                Ok(Some(schema)) => {
                    let body = serde_json::to_value(schema)
                        .map_err(|e| Error::from(format!("Serialization error: {}", e)))?;
                    json_response(200, body)
                }
                Ok(None) => json_response(404, json!({"error": "Schema not found"})),
                Err(e) => json_response(500, json!({"error": format!("Failed to get schema: {}", e)})),
            }
        }

        // Add schema (POST)
        ("POST", "/api/schemas") => {
            let body = match event.body() {
                Body::Text(s) => s.clone(),
                Body::Binary(b) => String::from_utf8_lossy(b).to_string(),
                Body::Empty => {
                    return json_response(400, json!({"error": "Request body is empty"}));
                }
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
                        return json_response(400, json!({"error": format!("Invalid schema: {}", e)}));
                    }
                },
                None => {
                    return json_response(400, json!({"error": "Missing 'schema' field"}));
                }
            };

            let mutation_mappers = request.get("mutation_mappers")
                .and_then(|m| serde_json::from_value(m.clone()).ok())
                .unwrap_or_default();

            match state.add_schema(schema, mutation_mappers).await {
                Ok(outcome) => {
                    json_response(200, json!({
                        "ok": true,
                        "outcome": format!("{:?}", outcome)
                    }))
                }
                Err(e) => json_response(500, json!({"error": format!("Failed to add schema: {}", e)})),
            }
        }

        // Reload schemas
        ("POST", "/api/schemas/reload") => {
            match state.load_schemas().await {
                Ok(_) => {
                    let count = state.get_schema_count();
                    json_response(200, json!({
                        "ok": true,
                        "count": count,
                        "message": format!("Reloaded {} schemas", count)
                    }))
                }
                Err(e) => json_response(500, json!({"error": format!("Failed to reload: {}", e)})),
            }
        }

        // Root endpoint
        ("GET", "/") | ("POST", "/") => {
            json_response(200, json!({
                "service": "FoldDB Schema Registry",
                "version": "1.0.0",
                "endpoints": {
                    "GET /health": "Health check",
                    "GET /api/schemas": "List schema names",
                    "GET /api/schemas/available": "Get all schemas with definitions",
                    "GET /api/schema/{name}": "Get specific schema",
                    "POST /api/schemas": "Add new schema",
                    "POST /api/schemas/reload": "Reload schemas from storage"
                }
            }))
        }

        // Not found
        _ => json_response(404, json!({"error": format!("Not found: {} {}", method, path)})),
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
