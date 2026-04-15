//! S3-backed implementation of `fold_db::schema_service::ExternalSchemaPersistence`.
//!
//! Layout (see `fold_db_node/docs/designs/schema_service_s3.md`):
//!
//! ```text
//! s3://{bucket}/
//! ├── schemas.json              # single JSON doc, every schema keyed by identity_hash
//! ├── canonical_fields.json     # every canonical field keyed by name
//! ├── views.json                # every view keyed by view name
//! ├── transforms.json           # every transform's metadata keyed by wasm hash
//! └── wasm/
//!     └── {wasm_hash}.wasm      # content-addressed WASM bytes, immutable
//! ```
//!
//! ## Concurrency model
//!
//! **Domain blobs (schemas, canonical_fields, views, transforms)** use
//! read-modify-write with an `If-Match: {etag}` precondition on PUT.
//! If another Lambda wrote in between our GET and our PUT, the ETag
//! changes and S3 returns 412 Precondition Failed; we re-read, re-merge,
//! and retry. Bounded retry count prevents retry storms.
//!
//! **WASM bytes** are content-addressed — the S3 key *is* the SHA-256
//! of the bytes. Writes use `If-None-Match: *` so a duplicate upload
//! fails with 412 (which we treat as idempotent success). There's no
//! read-modify-write cycle; every successful write is the first write.
//!
//! ## On the append-only invariant
//!
//! The schema service is append-only — nothing is ever deleted. This
//! means a cache populated from a past `load_all_*` call is always
//! correct for the keys it holds; it can only be *incomplete*, never
//! *wrong*. Writes go directly to S3 via conditional PUT and S3 is the
//! sole arbiter of who wins a race. See the design doc for the full
//! discussion.

use std::collections::HashMap;

use async_trait::async_trait;
use aws_sdk_s3::error::ProvideErrorMetadata;
use aws_sdk_s3::primitives::ByteStream;
use aws_sdk_s3::Client as S3Client;
use fold_db::error::{FoldDbError, FoldDbResult};
use fold_db::schema::types::Schema;
use fold_db::schema_service::external_persistence::ExternalSchemaPersistence;
use fold_db::schema_service::types::{CanonicalField, StoredView, TransformRecord};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};

// Blob keys inside the bucket.
const SCHEMAS_KEY: &str = "schemas.json";
const CANONICAL_FIELDS_KEY: &str = "canonical_fields.json";
const VIEWS_KEY: &str = "views.json";
const TRANSFORMS_KEY: &str = "transforms.json";
const WASM_PREFIX: &str = "wasm/";

/// How many times we retry a domain-blob PUT when the ETag precondition
/// fails. At alpha write rates (< 1/sec per domain) actual contention
/// is ~zero; this cap exists to bound retry storms if the service ever
/// approaches the blob contention ceiling.
const MAX_RMW_RETRIES: usize = 10;

/// Versioned envelope for each domain blob. The `version` field is
/// reserved for future on-disk format migrations; items inside are
/// free-form per domain type.
#[derive(Debug, Clone, Serialize, Deserialize)]
struct DomainBlob<T> {
    version: u32,
    #[serde(default = "HashMap::new")]
    items: HashMap<String, T>,
}

impl<T> Default for DomainBlob<T> {
    fn default() -> Self {
        Self {
            version: 1,
            items: HashMap::new(),
        }
    }
}

/// Persist schema-service state in four S3 JSON blobs plus a
/// content-addressed `wasm/` prefix. Implements
/// `ExternalSchemaPersistence` so the fold_db schema service can
/// delegate all persistence here without knowing it's backed by S3.
pub struct S3BlobPersistence {
    client: S3Client,
    bucket: String,
}

impl S3BlobPersistence {
    pub fn new(client: S3Client, bucket: String) -> Self {
        Self { client, bucket }
    }

    /// GET a domain blob. Returns `(blob, etag)`. On 404 (NoSuchKey),
    /// returns an empty default blob with `None` etag so the next PUT
    /// uses `If-None-Match: *` to create the key.
    async fn get_blob<T>(&self, key: &str) -> FoldDbResult<(DomainBlob<T>, Option<String>)>
    where
        T: DeserializeOwned,
    {
        let result = self
            .client
            .get_object()
            .bucket(&self.bucket)
            .key(key)
            .send()
            .await;

        match result {
            Ok(resp) => {
                let etag = resp.e_tag().map(String::from);
                let body = resp.body.collect().await.map_err(|e| {
                    FoldDbError::Config(format!("Failed to read S3 body for '{}': {}", key, e))
                })?;
                let bytes = body.into_bytes();
                if bytes.is_empty() {
                    return Ok((DomainBlob::default(), etag));
                }
                let blob: DomainBlob<T> = serde_json::from_slice(&bytes).map_err(|e| {
                    FoldDbError::Serialization(format!("Failed to parse S3 blob '{}': {}", key, e))
                })?;
                Ok((blob, etag))
            }
            Err(e) => {
                if error_code(&e).as_deref() == Some("NoSuchKey") {
                    Ok((DomainBlob::default(), None))
                } else {
                    Err(FoldDbError::Config(format!(
                        "Failed to get S3 object '{}': {}",
                        key,
                        short_error(&e)
                    )))
                }
            }
        }
    }

    /// Read-modify-write loop for a domain blob with ETag-based
    /// optimistic concurrency. Bounded retries on precondition failure.
    async fn update_blob<T, F>(&self, key: &str, modify: F) -> FoldDbResult<()>
    where
        T: Serialize + DeserializeOwned,
        F: Fn(&mut DomainBlob<T>) -> FoldDbResult<()>,
    {
        for attempt in 0..MAX_RMW_RETRIES {
            let (mut blob, etag) = self.get_blob::<T>(key).await?;
            modify(&mut blob)?;
            let body = serde_json::to_vec(&blob).map_err(|e| {
                FoldDbError::Serialization(format!("Failed to serialize blob '{}': {}", key, e))
            })?;

            let mut put = self
                .client
                .put_object()
                .bucket(&self.bucket)
                .key(key)
                .body(ByteStream::from(body))
                .content_type("application/json");

            // Optimistic concurrency:
            //   - blob existed  → require matching ETag (If-Match)
            //   - blob missing  → require key to still not exist (If-None-Match: *)
            put = match etag.as_deref() {
                Some(tag) => put.if_match(tag),
                None => put.if_none_match("*"),
            };

            match put.send().await {
                Ok(_) => return Ok(()),
                Err(e) if is_precondition_failed(&e) => {
                    tracing::warn!(
                        key = key,
                        attempt = attempt + 1,
                        "S3 blob ETag precondition failed — re-reading and retrying"
                    );
                    continue;
                }
                Err(e) => {
                    return Err(FoldDbError::Config(format!(
                        "Failed to put S3 object '{}': {}",
                        key,
                        short_error(&e)
                    )));
                }
            }
        }
        Err(FoldDbError::Config(format!(
            "Exceeded {} retries updating S3 blob '{}' (ETag contention)",
            MAX_RMW_RETRIES, key
        )))
    }
}

#[async_trait]
impl ExternalSchemaPersistence for S3BlobPersistence {
    async fn save_schema(&self, schema: &Schema) -> FoldDbResult<()> {
        let name = schema.name.clone();
        let schema = schema.clone();
        self.update_blob::<Schema, _>(SCHEMAS_KEY, move |blob| {
            blob.items.insert(name.clone(), schema.clone());
            Ok(())
        })
        .await
    }

    async fn load_all_schemas(&self) -> FoldDbResult<HashMap<String, Schema>> {
        let (blob, _) = self.get_blob::<Schema>(SCHEMAS_KEY).await?;
        Ok(blob.items)
    }

    async fn save_canonical_field(&self, name: &str, field: &CanonicalField) -> FoldDbResult<()> {
        let name = name.to_string();
        let field = field.clone();
        self.update_blob::<CanonicalField, _>(CANONICAL_FIELDS_KEY, move |blob| {
            blob.items.insert(name.clone(), field.clone());
            Ok(())
        })
        .await
    }

    async fn load_all_canonical_fields(&self) -> FoldDbResult<HashMap<String, CanonicalField>> {
        let (blob, _) = self
            .get_blob::<CanonicalField>(CANONICAL_FIELDS_KEY)
            .await?;
        Ok(blob.items)
    }

    async fn save_view(&self, view: &StoredView) -> FoldDbResult<()> {
        let name = view.name.clone();
        let view = view.clone();
        self.update_blob::<StoredView, _>(VIEWS_KEY, move |blob| {
            blob.items.insert(name.clone(), view.clone());
            Ok(())
        })
        .await
    }

    async fn load_all_views(&self) -> FoldDbResult<HashMap<String, StoredView>> {
        let (blob, _) = self.get_blob::<StoredView>(VIEWS_KEY).await?;
        Ok(blob.items)
    }

    async fn save_transform_metadata(&self, record: &TransformRecord) -> FoldDbResult<()> {
        let hash = record.hash.clone();
        let record = record.clone();
        self.update_blob::<TransformRecord, _>(TRANSFORMS_KEY, move |blob| {
            blob.items.insert(hash.clone(), record.clone());
            Ok(())
        })
        .await
    }

    async fn save_transform_wasm(&self, hash: &str, wasm_bytes: &[u8]) -> FoldDbResult<()> {
        let key = format!("{}{}.wasm", WASM_PREFIX, hash);
        let result = self
            .client
            .put_object()
            .bucket(&self.bucket)
            .key(&key)
            .body(ByteStream::from(wasm_bytes.to_vec()))
            .content_type("application/wasm")
            .if_none_match("*")
            .send()
            .await;
        match result {
            Ok(_) => Ok(()),
            Err(e) if is_precondition_failed(&e) => {
                // Content-addressed key already exists — byte-identical
                // content by construction, so treat as idempotent success.
                Ok(())
            }
            Err(e) => Err(FoldDbError::Config(format!(
                "Failed to upload WASM '{}': {}",
                key,
                short_error(&e)
            ))),
        }
    }

    async fn load_all_transforms(&self) -> FoldDbResult<HashMap<String, TransformRecord>> {
        let (blob, _) = self.get_blob::<TransformRecord>(TRANSFORMS_KEY).await?;
        Ok(blob.items)
    }

    async fn load_transform_wasm(&self, hash: &str) -> FoldDbResult<Option<Vec<u8>>> {
        let key = format!("{}{}.wasm", WASM_PREFIX, hash);
        let result = self
            .client
            .get_object()
            .bucket(&self.bucket)
            .key(&key)
            .send()
            .await;
        match result {
            Ok(resp) => {
                let body = resp.body.collect().await.map_err(|e| {
                    FoldDbError::Config(format!("Failed to read WASM body '{}': {}", key, e))
                })?;
                Ok(Some(body.into_bytes().to_vec()))
            }
            Err(e) if error_code(&e).as_deref() == Some("NoSuchKey") => Ok(None),
            Err(e) => Err(FoldDbError::Config(format!(
                "Failed to get WASM '{}': {}",
                key,
                short_error(&e)
            ))),
        }
    }
}

// -------- error introspection helpers --------
//
// aws-sdk-s3 v1 surfaces service errors via `ProvideErrorMetadata`,
// which returns an error code string like "NoSuchKey" or
// "PreconditionFailed". We match on the code rather than the SdkError
// variant so these helpers are operation-agnostic (GetObject, PutObject,
// etc. all surface the same shape).

fn error_code<E, R>(err: &aws_sdk_s3::error::SdkError<E, R>) -> Option<String>
where
    E: ProvideErrorMetadata,
{
    err.code().map(String::from)
}

fn is_precondition_failed<E, R>(err: &aws_sdk_s3::error::SdkError<E, R>) -> bool
where
    E: ProvideErrorMetadata,
{
    matches!(err.code(), Some("PreconditionFailed"))
}

fn short_error<E, R>(err: &aws_sdk_s3::error::SdkError<E, R>) -> String
where
    E: ProvideErrorMetadata,
{
    match err.code() {
        Some(code) => format!("{} — {}", code, err.message().unwrap_or("no error message")),
        None => "unknown S3 error (no error code in response)".to_string(),
    }
}
