import {
  Stack,
  StackProps,
  Duration,
  CfnOutput,
  CustomResource,
  Fn,
  RemovalPolicy,
} from "aws-cdk-lib";
import { Construct } from "constructs";
import * as s3 from "aws-cdk-lib/aws-s3";
import * as lambda from "aws-cdk-lib/aws-lambda";
import * as apigwv2 from "aws-cdk-lib/aws-apigatewayv2";
import * as apigwv2Integrations from "aws-cdk-lib/aws-apigatewayv2-integrations";
import * as acm from "aws-cdk-lib/aws-certificatemanager";
import * as iam from "aws-cdk-lib/aws-iam";
import * as dynamodb from "aws-cdk-lib/aws-dynamodb";
import * as cr from "aws-cdk-lib/custom-resources";
import { Environment } from "./environment";

export interface SchemaServiceStackProps extends StackProps {
  environment?: string;
}

export class SchemaServiceStack extends Stack {
  constructor(scope: Construct, id: string, props?: SchemaServiceStackProps) {
    super(scope, id, props);

    const environment = Environment.fromName(
      props?.environment,
      Stack.of(this).account,
    );
    const envName = environment.name;

    // Backend Sentry config, added to the request-path Lambda. The DSN is
    // sourced from the OBS_SENTRY_DSN secret at synth time (deploy.sh exports
    // it). Empty when unset, in which case `observability::init_lambda` leaves
    // the Sentry sink off and CloudWatch logging is unchanged. Like the
    // frontend's VITE_SENTRY_DSN it is a write-only client token, not a
    // confidential secret, so a plaintext env var is appropriate.
    //
    // OBS_SENTRY_RELEASE tags events with the exact deploy SHA/version, and
    // OBS_SENTRY_ENVIRONMENT separates dev/prod events in Sentry. The fold
    // observability crate reads these names directly when it builds
    // sentry::ClientOptions.
    const obsSentryDsn = process.env.OBS_SENTRY_DSN ?? "";
    const obsSentryRelease =
      process.env.OBS_SENTRY_RELEASE ?? process.env.OBS_RELEASE ?? "";
    const obsSentryEnvironment =
      process.env.OBS_SENTRY_ENVIRONMENT ?? envName;

    // =====================================================
    // S3 Bucket for Schema Service state
    //
    // Domain blobs (schemas, canonical fields, apps, near-misses, etc.)
    // live in this bucket. Writes use If-Match ETag RMW for JSON blobs.
    // Transform/view/WASM plane storage was ripped; do not reintroduce
    // views.json / transforms.json / wasm/ as product surfaces.
    //
    // Versioning is enabled so we keep rollback history if a bad PUT
    // ever corrupts a blob. S3 versioning costs pennies at this scale.
    // =====================================================
    const schemaBucket = new s3.Bucket(this, "SchemaBucket", {
      bucketName: `schema-service-${envName}-${Stack.of(this).account}`,
      versioned: true,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      encryption: s3.BucketEncryption.S3_MANAGED,
      removalPolicy: RemovalPolicy.RETAIN,
      enforceSSL: true,
    });

    // =====================================================
    // Fastembed Model Layer
    //
    // The schema service uses fastembed (all-MiniLM-L6-v2 ONNX) for
    // semantic matching of schema names and canonical fields. Pulling
    // the model from HuggingFace at cold start cost ~40s of wasted
    // retries before falling back to a heuristic — see the CloudWatch
    // trace in PR #11 for the before-picture.
    //
    // We ship the model as a Layer rather than bundling it in the
    // function zip so that:
    //   - function code stays ~20MB and iterates in seconds on deploy;
    //   - the 90MB model is uploaded once per model-version change,
    //     not on every code edit;
    //   - layer content lands at /opt/ in the running Lambda, which
    //     matches the FASTEMBED_CACHE_DIR=/opt/fastembed_cache set by
    //     the function (see schema_service submodule's server_lambda).
    //
    // The layer asset directory is populated by build.sh — it downloads
    // the five files fastembed needs (model.onnx + four tokenizer
    // files) from the pinned HF revision into hf-hub 0.4 cache layout.
    // =====================================================
    const fastembedLayer = new lambda.LayerVersion(this, "FastembedModelLayer", {
      code: lambda.Code.fromAsset(
        "../target/fastembed_layer",
      ),
      compatibleRuntimes: [lambda.Runtime.PROVIDED_AL2023],
      compatibleArchitectures: [lambda.Architecture.X86_64],
      description:
        "fastembed all-MiniLM-L6-v2 ONNX model + tokenizer files at /opt/fastembed_cache/",
      removalPolicy: RemovalPolicy.RETAIN,
    });

    // =====================================================
    // App identity v3.1 — trusted root pubkey from exemem-infra
    //
    // schema_service verifies DevCert envelopes offline against a set
    // of trusted exemem root P-256 SubjectPublicKeyInfo DER pubkeys
    // (see `fold/schema_service/crates/core/src/app_identity.rs`
    // `parse_trusted_roots`). Without APP_IDENTITY_ROOT_PUBKEYS, the
    // Lambda rejects every dev cert with 401 and the owner_app_id
    // gate on POST /v1/schemas silently degrades to a passthrough
    // (`server_lambda/src/main.rs:446-460`).
    //
    // The pubkey lives in KMS in the peer exemem-infra stack at alias
    // `exemem-app-identity-root-{env}`. KMS does NOT expose the pubkey
    // bytes via CFN output, so we fetch them at deploy time via a
    // CloudFormation Custom Resource and inject the base64-encoded
    // SPKI DER as the Lambda env var.
    //
    // Algorithm is ES256 (P-256 / ECDSA_SHA_256), not Ed25519 — AWS
    // KMS has no `ECC_ED25519` key spec. See
    // `exemem-infra/.task-blocked.md` and the v3.1 design doc decision
    // log (2026-05-29 entry).
    // =====================================================
    const appIdentityRootKeyArn = Fn.importValue(
      `ExememAppIdentityRootKeyArn-${envName}`,
    );
    // Custom resource that fetches the SPKI pubkey from KMS at deploy
    // time and stores it as a single base64 string field in the CFN
    // response. The prior `cr.AwsCustomResource` form tripped the
    // 4096-byte response limit because AwsCustomResource flattens the
    // raw KMS response — `PublicKey` arrives as a `Uint8Array`, which
    // the response flattener walks into per-byte keys
    // (`PublicKey.0`, `PublicKey.1`, …). `outputPaths: ["PublicKey"]`
    // is a prefix filter, so it keeps all of those flattened bytes and
    // does nothing. Replacing with a small Provider-backed Lambda lets
    // us base64-encode the bytes once and return a single ~150-byte
    // string field, well under the limit.
    const appIdentityRootPubkeyHandler = new lambda.Function(
      this,
      "AppIdentityRootPubkeyHandler",
      {
        runtime: lambda.Runtime.NODEJS_20_X,
        handler: "index.handler",
        timeout: Duration.seconds(30),
        code: lambda.Code.fromInline(
          `const { KMSClient, GetPublicKeyCommand } = require("@aws-sdk/client-kms");
exports.handler = async (event) => {
  const physicalResourceId =
    event.PhysicalResourceId ||
    "app-identity-root-pubkey-" + (event.ResourceProperties.Env || "dev");
  if (event.RequestType === "Delete") {
    return { PhysicalResourceId: physicalResourceId };
  }
  const keyId = event.ResourceProperties.KeyId;
  const client = new KMSClient({});
  const resp = await client.send(new GetPublicKeyCommand({ KeyId: keyId }));
  if (!resp.PublicKey) {
    throw new Error("KMS GetPublicKey returned no PublicKey for " + keyId);
  }
  const publicKeyB64 = Buffer.from(resp.PublicKey).toString("base64");
  return {
    PhysicalResourceId: physicalResourceId,
    Data: { PublicKeyB64: publicKeyB64 },
  };
};
`,
        ),
      },
    );
    appIdentityRootPubkeyHandler.addToRolePolicy(
      new iam.PolicyStatement({
        actions: ["kms:GetPublicKey"],
        resources: [appIdentityRootKeyArn],
      }),
    );
    const appIdentityRootPubkeyProvider = new cr.Provider(
      this,
      "AppIdentityRootPubkeyProvider",
      {
        onEventHandler: appIdentityRootPubkeyHandler,
      },
    );
    const appIdentityRootPubkeyFetcher = new CustomResource(
      this,
      "AppIdentityRootPubkeyFetcher",
      {
        serviceToken: appIdentityRootPubkeyProvider.serviceToken,
        properties: {
          KeyId: appIdentityRootKeyArn,
          Env: envName,
        },
      },
    );
    // PublicKeyB64 is the base64-encoded SubjectPublicKeyInfo DER bytes
    // returned by KMS GetPublicKey. The Lambda decodes it with
    // `BASE64.decode(entry)` and derives the envelope `key_id` as
    // `hex(sha256(SPKI DER))`. Resolved at deploy time.
    const appIdentityRootPubkeyB64 =
      appIdentityRootPubkeyFetcher.getAttString("PublicKeyB64");

    // =====================================================
    // Schema Service Lambda Function
    // =====================================================
    // Lambda source lives in the `fold` monorepo (submodule at
    // `schema-infra/fold/`). The build pipeline in `build.sh` runs
    // `cargo lambda build -p schema_service_server_lambda` from the
    // monorepo's workspace root and extracts the resulting bootstrap.zip
    // to the path referenced below.
    const schemaServiceFn = new lambda.Function(this, "SchemaServiceFn", {
      runtime: lambda.Runtime.PROVIDED_AL2023,
      handler: "bootstrap",
      code: lambda.Code.fromAsset(
        "../fold/target/lambda/server_lambda-extracted",
      ),
      layers: [fastembedLayer],
      // First cold start on an empty bucket seeds built-in schemas and
      // RMW-persists domain blobs. Once populated, later cold starts
      // load blobs (< 1s); warm invocations complete in milliseconds.
      timeout: Duration.seconds(300),
      memorySize: 512,
      environment: {
        RUST_LOG: "info",
        OBS_SENTRY_DSN: obsSentryDsn,
        OBS_SENTRY_RELEASE: obsSentryRelease,
        OBS_SENTRY_ENVIRONMENT: obsSentryEnvironment,
        // The schema service persists all state in this S3 bucket via
        // S3BlobPersistence. No filesystem required, no VPC, no EFS.
        // User-submitted schemas and canonical fields persist across
        // cold starts because S3 is the source of truth.
        SCHEMA_STORE_BUCKET: schemaBucket.bucketName,
        // Dev-only: activate Phase B's dual-signal canonicalization
        // gate so the `fold-dev-node` dogfood loop stops collapsing
        // structurally-identical inputs into the wrong canonical.
        // Prod stays on the single-signal default until Phase E (fold
        // workspace task `20340`) ships the default flip after Phase C
        // (`68e3a`) lands + threshold tuning settles. Phase D backfill
        // populated `purpose_statement` on every existing canonical in
        // this bucket, so the embedder has a real second signal here.
        ...(environment.isDev
          ? { SCHEMA_DUAL_SIGNAL_CANONICALIZATION: "true" }
          : {}),
        // App identity v3.1 (Lanes B2b/B2c). See the Custom Resource
        // block above for the pubkey fetch + ES256/Ed25519 note.
        //
        // ENVIRONMENT binds DevCert envelopes to this deployment:
        // `prod`/`production` → Env::Prod, anything else → Env::Dev
        // (per `deployment_env_from_process` in app_identity.rs:234).
        // Cross-env certs (a `prod`-bound envelope replayed against
        // `dev`) are rejected at verification.
        ENVIRONMENT: envName,
        // Trusted exemem root pubkeys (comma-separated base64 SPKI DER)
        // for offline DevCert verification. With none, /v1/apps 401s
        // every cert and owner_app_id on /v1/schemas is a passthrough.
        APP_IDENTITY_ROOT_PUBKEYS: appIdentityRootPubkeyB64,
        // Cross-env mirror (Lane B2c) — INACTIVE in v1. The mirror
        // activates only when BOTH of the following are set:
        //   CROSS_ENV_MIRROR_PEERS — comma-separated env=url pairs,
        //     e.g. "prod=https://axo709qs11.execute-api.us-east-1.amazonaws.com"
        //   CROSS_ENV_MIRROR_TOKEN — shared secret across peer envs
        // Without them the dev env claims an app_id locally, the
        // scheduled `POST /v1/admin/reconcile-apps` is the only
        // mechanism that surfaces cross-env divergence, and the
        // initial publish to each env is manual. When both envs are
        // live and have a shared SSM/Secrets-Manager token, wire
        // those here. See `docs/cross_env_mirror_runbook.md`.
        // CROSS_ENV_MIRROR_PEERS: "prod=https://axo709qs11.execute-api.us-east-1.amazonaws.com",
        // CROSS_ENV_MIRROR_TOKEN: <SecretValue>.toString(),
      },
    });

    // Grant Lambda read/write on the schema bucket (domain blobs).
    schemaBucket.grantReadWrite(schemaServiceFn);

    // `live` alias is the traffic seam for staged canary deploys:
    // post-deploy scripts pin 10% of prod traffic on a new version for
    // CANARY_SOAK_HOURS (default 24h), then promote to 100% if alarms stay
    // green. See scripts/deploy/* and .lastgit/deploy-pipeline.sh.
    const schemaServiceLive = new lambda.Alias(this, "SchemaServiceLiveAlias", {
      aliasName: "live",
      version: schemaServiceFn.currentVersion,
    });

    // Every route points at the `live` alias (not $LATEST), so canary weights
    // apply. Call sites just supply the integration id.
    const lambdaIntegration = (id: string) =>
      new apigwv2Integrations.HttpLambdaIntegration(id, schemaServiceLive);

    // =====================================================
    // HTTP API Gateway with CORS
    // =====================================================
    const httpApi = new apigwv2.HttpApi(this, "SchemaHttpApi", {
      apiName: `schema-service-${envName}`,
      corsPreflight: {
        allowOrigins: ["*"],
        allowMethods: [
          apigwv2.CorsHttpMethod.GET,
          apigwv2.CorsHttpMethod.POST,
          apigwv2.CorsHttpMethod.OPTIONS
        ],
        allowHeaders: ["Content-Type", "Authorization"],
        maxAge: Duration.days(1),
      },
    });

    // Rate limiting: 100 requests/second with burst to 200
    const stage = httpApi.defaultStage?.node
      .defaultChild as apigwv2.CfnStage;
    stage.defaultRouteSettings = {
      throttlingBurstLimit: 200,
      throttlingRateLimit: 100,
    };

    // Root endpoint
    httpApi.addRoutes({
      path: "/",
      methods: [apigwv2.HttpMethod.GET, apigwv2.HttpMethod.POST],
      integration: lambdaIntegration("SchemaRootIntegration"),
    });

    // Health check endpoint
    httpApi.addRoutes({
      path: "/health",
      methods: [apigwv2.HttpMethod.GET],
      integration: lambdaIntegration("SchemaHealthIntegration"),
    });

    // =====================================================
    // Route definitions — /v1 only.
    //
    // The Lambda dispatch is /v1-only (explicitly rejects /api/*).
    // Transform / view / WASM / triggers gateway routes were product-
    // ripped; do not re-mount them. Keep only live schema/apps/snapshot
    // surfaces that server_lambda still handles.
    // =====================================================
    const v1Routes: Array<{
      path: string;
      methods: apigwv2.HttpMethod[];
      integrationId: string;
    }> = [
      {
        path: "/v1/health",
        methods: [apigwv2.HttpMethod.GET],
        integrationId: "SchemaHealthIntegrationV1",
      },
      {
        path: "/v1/schemas",
        methods: [apigwv2.HttpMethod.GET, apigwv2.HttpMethod.POST],
        integrationId: "SchemaListIntegrationV1",
      },
      {
        path: "/v1/schemas/available",
        methods: [apigwv2.HttpMethod.GET],
        integrationId: "SchemaAvailableIntegrationV1",
      },
      {
        path: "/v1/schemas/similar/{schemaId}",
        methods: [apigwv2.HttpMethod.GET],
        integrationId: "SchemaSimilarIntegrationV1",
      },
      {
        path: "/v1/schemas/{schemaId}",
        methods: [apigwv2.HttpMethod.GET],
        integrationId: "SchemaGetIntegrationV1",
      },
      {
        // Singular /schema/{schemaId} used by FoldDB client
        path: "/v1/schema/{schemaId}",
        methods: [apigwv2.HttpMethod.GET],
        integrationId: "SchemaGetSingularIntegrationV1",
      },
      {
        path: "/v1/schemas/batch-check-reuse",
        methods: [apigwv2.HttpMethod.POST],
        integrationId: "SchemaBatchCheckReuseIntegrationV1",
      },
      {
        // Stateless dedupe for Mini cache misses. Fresh LastDB nodes call this
        // through /api/apps/declare-schema during first fkanban/fbrain init.
        path: "/v1/schemas/resolve",
        methods: [apigwv2.HttpMethod.POST],
        integrationId: "SchemaResolveIntegrationV1",
      },
      {
        path: "/v1/schemas/reload",
        methods: [apigwv2.HttpMethod.POST],
        integrationId: "SchemaReloadIntegrationV1",
      },
      {
        // Admin one-shot: backfill embeddings for every schema and
        // canonical field that doesn't yet have a persisted embedding
        // in the `schema-embeddings-${env}` DynamoDB table. Idempotent
        // — subsequent calls skip already-persisted entries and return
        // counts of computed + skipped per kind. Hit once after first
        // deploying the DDB-backed embedding store (schema_service #46).
        path: "/v1/admin/warm-embeddings",
        methods: [apigwv2.HttpMethod.POST],
        integrationId: "AdminWarmEmbeddingsIntegrationV1",
      },
      {
        // Auth-gated registry export. Lambda validates `X-API-Key`
        // against the cross-stack-imported `ApiKeys` DynamoDB table
        // and returns a `SnapshotEnvelope` on success.
        path: "/v1/snapshot",
        methods: [apigwv2.HttpMethod.GET],
        integrationId: "SnapshotExportIntegrationV1",
      },
      {
        // Auth-gated shared-only registry export for resolver packs.
        path: "/v1/snapshot/shared-only",
        methods: [apigwv2.HttpMethod.GET],
        integrationId: "SnapshotSharedOnlyExportIntegrationV1",
      },
      // App identity v3.1 — required for owner_app_id publish gate.
      {
        path: "/v1/apps",
        methods: [apigwv2.HttpMethod.POST],
        integrationId: "AppRegisterIntegrationV1",
      },
      {
        path: "/v1/apps/{app_id}",
        methods: [apigwv2.HttpMethod.GET],
        integrationId: "AppGetIntegrationV1",
      },
      {
        path: "/v1/apps/{app_id}/promote",
        methods: [apigwv2.HttpMethod.POST],
        integrationId: "AppPromoteIntegrationV1",
      },
    ];

    for (const route of v1Routes) {
      httpApi.addRoutes({
        path: route.path,
        methods: route.methods,
        integration: lambdaIntegration(route.integrationId),
      });
    }

    // =====================================================
    // Schema embeddings — DynamoDB table.
    // =====================================================

    // Embeddings table. Single table, two kinds share via partition key:
    //   PK `kind` (S) = "descriptive_name" | "canonical_field"
    //   SK `key`  (S) = schema identity_hash | canonical field name
    //
    // Write path (add_schema / add_canonical_field) PutItems one row
    // per new embedding. Cold start Queries per kind, paginated 1MB
    // pages. O(1) writes vs. the single-blob S3 approach that RMW'd
    // the whole blob on every update — see schema_service #46.
    //
    // PAY_PER_REQUEST: at current volume (dozens of writes per day,
    // one cold-start Query pair per Lambda cold start) on-demand
    // billing is a few cents per month, simpler than capacity
    // planning. Revisit if per-minute traffic ever exceeds
    // ~10 writes/sec sustained.
    const embeddingsTable = new dynamodb.Table(this, "SchemaEmbeddingsTable", {
      tableName: `schema-embeddings-${envName}`,
      partitionKey: {
        name: "kind",
        type: dynamodb.AttributeType.STRING,
      },
      sortKey: {
        name: "key",
        type: dynamodb.AttributeType.STRING,
      },
      billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
      // Dev is DESTROY so a stack teardown doesn't leave orphan tables.
      // Prod is RETAIN — embeddings are cheap to recompute but mostly
      // free to keep around, and accidental destroy would force every
      // cold start to re-embed until the warm-embeddings backfill
      // re-ran.
      removalPolicy: environment.isProd
        ? RemovalPolicy.RETAIN
        : RemovalPolicy.DESTROY,
    });

    // Request-path Lambda reads + writes the embeddings table:
    // PutItem on every `add_schema` / `add_canonical_field`, Query
    // on cold start to populate the in-memory cache.
    embeddingsTable.grantReadWriteData(schemaServiceFn);
    schemaServiceFn.addEnvironment(
      "SCHEMA_EMBEDDINGS_TABLE",
      embeddingsTable.tableName,
    );

    // =====================================================
    // Cross-stack auth wire — `GET /v1/snapshot` validates
    // `X-API-Key` against the exemem `ApiKeys` DynamoDB table.
    //
    // The schema_service Lambda reuses
    // `exemem_common::api_key::validate_api_key` (SHA-256 hash +
    // DynamoDB GetItem) — same path `storage_service` uses, no
    // Lambda-to-Lambda invoke. The table is owned by the exemem-infra
    // stack and exported as `ExememApiKeysTableName-{env}`
    // (exemem-infra PR #154). This stack imports the name, derives the
    // ARN, and grants the function `dynamodb:GetItem` on it.
    //
    // Same-region / same-account cross-stack import: dev is
    // us-west-2 / prod is us-east-1, and exemem-infra deploys to
    // identical regions, so `Fn.importValue` resolves locally without
    // CFN cross-region complications.
    // =====================================================
    const apiKeysTableName = Fn.importValue(
      `ExememApiKeysTableName-${envName}`,
    );
    const apiKeysTableArn = Stack.of(this).formatArn({
      service: "dynamodb",
      resource: "table",
      resourceName: apiKeysTableName,
    });
    schemaServiceFn.addToRolePolicy(
      new iam.PolicyStatement({
        sid: "ValidateExememApiKeys",
        actions: ["dynamodb:GetItem"],
        // Validation is a hashed-key lookup against the partition key
        // (`api_key_hash`); no scans, no GSI reads. Scoping to GetItem
        // keeps blast radius minimal even if the role is misused.
        resources: [apiKeysTableArn],
      }),
    );
    schemaServiceFn.addEnvironment("API_KEYS_TABLE", apiKeysTableName);

    // =====================================================
    // Custom Domain (schema.folddb.com) — prod only
    // =====================================================
    // WARNING: Do NOT rename the construct IDs below ("SchemaDomainCert",
    // "SchemaDomainName", "SchemaApiMapping"). Changing them causes
    // CloudFormation to delete+recreate the API Gateway domain, which
    // generates a new CNAME target and requires a DNS update.
    if (environment.isProd) {
      const schemaCert = acm.Certificate.fromCertificateArn(
        this,
        "SchemaDomainCert",
        environment.acmCertificateArn(
          "18c59c49-1581-48b4-ba6c-402bfd3ac2d6",
        ),
      );

      const schemaDomainName = new apigwv2.DomainName(
        this,
        "SchemaDomainName",
        {
          domainName: "schema.folddb.com",
          certificate: schemaCert,
        },
      );

      new apigwv2.ApiMapping(this, "SchemaApiMapping", {
        api: httpApi,
        domainName: schemaDomainName,
      });

      new CfnOutput(this, "SchemaServiceDomain", {
        value: "schema.folddb.com",
        description: "Custom domain for schema service",
      });

      new CfnOutput(this, "SchemaServiceDomainTarget", {
        value: schemaDomainName.regionalDomainName,
        description: "API Gateway domain target for DNS CNAME record",
      });
    }

    // =====================================================
    // Outputs
    // =====================================================
    new CfnOutput(this, "SchemaServiceApiUrl", {
      value: httpApi.apiEndpoint,
      description: "Schema service API endpoint",
    });

    new CfnOutput(this, "SchemaServiceBucketName", {
      value: schemaBucket.bucketName,
      description: "S3 bucket backing the schema service state",
    });

    new CfnOutput(this, "SchemaServiceFunctionName", {
      value: schemaServiceFn.functionName,
      description: "Schema service Lambda function name",
    });

    new CfnOutput(this, "SchemaServiceLiveAliasName", {
      value: schemaServiceLive.functionName,
      description: "Qualified live alias name (function:live) for canary traffic",
    });
  }
}
