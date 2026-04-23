import {
  Stack,
  StackProps,
  Duration,
  CfnOutput,
  RemovalPolicy,
  Size,
} from "aws-cdk-lib";
import { Construct } from "constructs";
import * as s3 from "aws-cdk-lib/aws-s3";
import * as lambda from "aws-cdk-lib/aws-lambda";
import * as apigwv2 from "aws-cdk-lib/aws-apigatewayv2";
import * as apigwv2Integrations from "aws-cdk-lib/aws-apigatewayv2-integrations";
import * as acm from "aws-cdk-lib/aws-certificatemanager";
import * as secretsmanager from "aws-cdk-lib/aws-secretsmanager";
import * as dynamodb from "aws-cdk-lib/aws-dynamodb";
import * as sqs from "aws-cdk-lib/aws-sqs";
import * as lambdaEventSources from "aws-cdk-lib/aws-lambda-event-sources";
import * as path from "path";

export interface SchemaServiceStackProps extends StackProps {
  environment?: string; // 'dev' or 'prod'
}

export class SchemaServiceStack extends Stack {
  constructor(scope: Construct, id: string, props?: SchemaServiceStackProps) {
    super(scope, id, props);

    const envName = props?.environment || "dev";
    const isProd = envName === "prod";

    // =====================================================
    // S3 Bucket for Schema Service state
    //
    // The schema service persists its state in four JSON domain blobs
    // plus a wasm/ prefix, all inside this bucket:
    //
    //   schemas.json            - all registered schemas
    //   canonical_fields.json   - global canonical field registry
    //   views.json              - registered views
    //   transforms.json         - transform metadata (NMI matrix, etc.)
    //   wasm/{hash}.wasm        - content-addressed WASM bytes
    //
    // Writes use If-Match ETag read-modify-write for the domain blobs
    // and If-None-Match for content-addressed WASM. See the design at
    // fold_db_node/docs/designs/schema_service_s3.md for the full
    // architecture, including scale ceiling and migration triggers.
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
    // Secrets
    // =====================================================
    const anthropicApiKey = secretsmanager.Secret.fromSecretNameV2(
      this,
      "AnthropicApiKey",
      `SchemaServiceAnthropicApiKey-${envName}`,
    );

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
    // Schema Service Lambda Function
    // =====================================================
    // Lambda source lives in the `schema_service` repo (submodule at
    // `schema-infra/schema_service/`). The build pipeline in `build.sh`
    // runs `cargo lambda build -p schema_service_server_lambda` inside
    // the submodule and extracts the resulting bootstrap.zip to the
    // path referenced below. See `projects/phase-1-t4-cdk-switch` for
    // the cutover rationale.
    const schemaServiceFn = new lambda.Function(this, "SchemaServiceFn", {
      runtime: lambda.Runtime.PROVIDED_AL2023,
      handler: "bootstrap",
      code: lambda.Code.fromAsset(
        "../schema_service/target/lambda/server_lambda-extracted",
      ),
      layers: [fastembedLayer],
      // First cold start on an empty bucket seeds 12 Phase 1 built-in
      // schemas. Each schema triggers canonical-field registration
      // (LLM classify) + RMW persistence to canonical_fields.json and
      // schemas.json. On a fresh bucket this can take 2–3 minutes
      // total. Once the blobs are populated, every later cold start
      // just loads the blobs (< 1s) and the seed returns AlreadyExists
      // without any S3 writes, so warm invocations complete in
      // milliseconds.
      timeout: Duration.seconds(300),
      memorySize: 512,
      environment: {
        RUST_LOG: "info",
        ANTHROPIC_API_KEY_SECRET_ARN: anthropicApiKey.secretArn,
        // The schema service persists all state in this S3 bucket via
        // S3BlobPersistence. No filesystem required, no VPC, no EFS.
        // User-submitted schemas and canonical fields persist across
        // cold starts because S3 is the source of truth.
        SCHEMA_STORE_BUCKET: schemaBucket.bucketName,
      },
    });

    // Grant Lambda access to Anthropic API key secret
    anthropicApiKey.grantRead(schemaServiceFn);

    // Grant Lambda read/write on the schema bucket. We scope to the
    // four known domain blob keys plus the wasm/ prefix so an errant
    // Lambda bug can't touch unrelated keys in the bucket.
    schemaBucket.grantReadWrite(schemaServiceFn);

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
      integration: new apigwv2Integrations.HttpLambdaIntegration(
        "SchemaRootIntegration",
        schemaServiceFn,
      ),
    });

    // Health check endpoint
    httpApi.addRoutes({
      path: "/health",
      methods: [apigwv2.HttpMethod.GET],
      integration: new apigwv2Integrations.HttpLambdaIntegration(
        "SchemaHealthIntegration",
        schemaServiceFn,
      ),
    });

    // =====================================================
    // Route definitions
    //
    // Every public path is registered under BOTH /api/* and /v1/*.
    // Phase 0 of the schema_service extraction introduced /v1/* as the
    // canonical prefix; /api/* stays in place for the transition and is
    // dropped in Phase 1 when this Lambda is absorbed into the
    // schema_service repo. The Lambda handler (main.rs) matches either
    // prefix to the same dispatch arm, so only the API Gateway routing
    // needs to be duplicated here.
    // =====================================================
    const schemaPaths: Array<{
      api: string;
      v1: string;
      methods: apigwv2.HttpMethod[];
      integrationId: string;
    }> = [
      {
        api: "/api/schemas",
        v1: "/v1/schemas",
        methods: [apigwv2.HttpMethod.GET, apigwv2.HttpMethod.POST],
        integrationId: "SchemaListIntegration",
      },
      {
        api: "/api/schemas/available",
        v1: "/v1/schemas/available",
        methods: [apigwv2.HttpMethod.GET],
        integrationId: "SchemaAvailableIntegration",
      },
      {
        api: "/api/schemas/similar/{schemaId}",
        v1: "/v1/schemas/similar/{schemaId}",
        methods: [apigwv2.HttpMethod.GET],
        integrationId: "SchemaSimilarIntegration",
      },
      {
        api: "/api/schemas/{schemaId}",
        v1: "/v1/schemas/{schemaId}",
        methods: [apigwv2.HttpMethod.GET],
        integrationId: "SchemaGetIntegration",
      },
      {
        // Singular /schema/{schemaId} used by FoldDB client
        api: "/api/schema/{schemaId}",
        v1: "/v1/schema/{schemaId}",
        methods: [apigwv2.HttpMethod.GET],
        integrationId: "SchemaGetSingularIntegration",
      },
      {
        api: "/api/views",
        v1: "/v1/views",
        methods: [apigwv2.HttpMethod.GET, apigwv2.HttpMethod.POST],
        integrationId: "ViewListIntegration",
      },
      {
        api: "/api/views/available",
        v1: "/v1/views/available",
        methods: [apigwv2.HttpMethod.GET],
        integrationId: "ViewAvailableIntegration",
      },
      {
        api: "/api/view/{viewId}",
        v1: "/v1/view/{viewId}",
        methods: [apigwv2.HttpMethod.GET],
        integrationId: "ViewGetIntegration",
      },
    ];

    for (const route of schemaPaths) {
      httpApi.addRoutes({
        path: route.api,
        methods: route.methods,
        integration: new apigwv2Integrations.HttpLambdaIntegration(
          route.integrationId,
          schemaServiceFn,
        ),
      });
      httpApi.addRoutes({
        path: route.v1,
        methods: route.methods,
        integration: new apigwv2Integrations.HttpLambdaIntegration(
          `${route.integrationId}V1`,
          schemaServiceFn,
        ),
      });
    }

    // /v1/health alongside the existing /health route.
    httpApi.addRoutes({
      path: "/v1/health",
      methods: [apigwv2.HttpMethod.GET],
      integration: new apigwv2Integrations.HttpLambdaIntegration(
        "SchemaHealthIntegrationV1",
        schemaServiceFn,
      ),
    });

    // =====================================================
    // Routes added for the new server_lambda (Phase 1 PR 4/5).
    //
    // These eight endpoints land in the Lambda via Phase 1 PR 2/5 and
    // close the parity gap with the actix wrapper. They are /v1-only —
    // the old in-tree Lambda never served them, so there is no /api/*
    // path to keep alive. `POST /v1/schemas/reload` is also added
    // because the new handler exposes it (the old one did not).
    // =====================================================
    const v1OnlyRoutes: Array<{
      path: string;
      methods: apigwv2.HttpMethod[];
      integrationId: string;
    }> = [
      {
        path: "/v1/schemas/batch-check-reuse",
        methods: [apigwv2.HttpMethod.POST],
        integrationId: "SchemaBatchCheckReuseIntegrationV1",
      },
      {
        path: "/v1/schemas/reload",
        methods: [apigwv2.HttpMethod.POST],
        integrationId: "SchemaReloadIntegrationV1",
      },
      {
        path: "/v1/transforms",
        methods: [apigwv2.HttpMethod.GET, apigwv2.HttpMethod.POST],
        integrationId: "TransformListIntegrationV1",
      },
      {
        path: "/v1/transforms/available",
        methods: [apigwv2.HttpMethod.GET],
        integrationId: "TransformAvailableIntegrationV1",
      },
      {
        path: "/v1/transforms/verify",
        methods: [apigwv2.HttpMethod.POST],
        integrationId: "TransformVerifyIntegrationV1",
      },
      {
        path: "/v1/transforms/similar/{name}",
        methods: [apigwv2.HttpMethod.GET],
        integrationId: "TransformSimilarIntegrationV1",
      },
      {
        path: "/v1/transform/{hash}",
        methods: [apigwv2.HttpMethod.GET],
        integrationId: "TransformGetIntegrationV1",
      },
      {
        // NB: API Gateway HTTP API path variables are single-segment
        // by design (no greedy `{hash+}`), so `/v1/transform/{hash}/wasm`
        // is a separate route — matched before the parent `{hash}` arm
        // in the Lambda's dispatch, but API Gateway routes both here
        // regardless of order.
        path: "/v1/transform/{hash}/wasm",
        methods: [apigwv2.HttpMethod.GET],
        integrationId: "TransformWasmIntegrationV1",
      },
      {
        // `projects/transform-worker-split` Lane A T4: async compile
        // job status endpoint. Client POSTs /v1/transforms, gets
        // 202 + job_id, polls here until Succeeded / failure. Lambda
        // dispatch arm matches `/v1/transform-jobs/...` and reads
        // the DynamoDB transform-jobs row.
        path: "/v1/transform-jobs/{jobId}",
        methods: [apigwv2.HttpMethod.GET],
        integrationId: "TransformJobStatusIntegrationV1",
      },
    ];

    for (const route of v1OnlyRoutes) {
      httpApi.addRoutes({
        path: route.path,
        methods: route.methods,
        integration: new apigwv2Integrations.HttpLambdaIntegration(
          route.integrationId,
          schemaServiceFn,
        ),
      });
    }

    // =====================================================
    // Async compile worker — DynamoDB jobs table, SQS queue, DLQ.
    //
    // See `projects/transform-worker-split` in gbrain for the full
    // design. The request-path Lambda enqueues a compile job on the
    // SQS queue; the worker (below) pulls the job, runs the real
    // Rust → WASM compile outside the 29s API Gateway timeout, and
    // writes the terminal status to the jobs table. Clients poll the
    // job by `job_id = source_hash`.
    //
    // All three resources are created together — they're a single
    // cohesive async pipeline and splitting them into separate stacks
    // would force cross-stack ARN exports for no gain.
    // =====================================================

    // DynamoDB table for per-job terminal status.
    //
    // Schema:
    //   PK:         job_id        (String, = SHA-256 of rust_source)
    //   status:     Succeeded | CompileFailed | CompileTimeout |
    //               InvalidOutputShape | TransformPanicked
    //   record:     JSON-serialized TransformRecord (on Succeeded only)
    //   error_message: free-text detail (on failure only)
    //   updated_at: epoch seconds
    //   ttl:        epoch seconds — 24h after updated_at
    //
    // `job_id` = source-hash gives deterministic atomic dedup via
    // conditional put — SQS redelivery after a successful first
    // commit is a no-op. TTL is enabled so orphan rows (from the
    // "SQS send fails after DynamoDB put" failure mode documented in
    // the plan) self-clean.
    const transformJobsTable = new dynamodb.Table(this, "TransformJobsTable", {
      tableName: `transform-jobs-${envName}`,
      partitionKey: {
        name: "job_id",
        type: dynamodb.AttributeType.STRING,
      },
      billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
      timeToLiveAttribute: "ttl",
      // Dev can be torn down and rebuilt; prod is RETAIN because we
      // don't want an accidental `cdk destroy` to wipe live job history.
      removalPolicy: isProd ? RemovalPolicy.RETAIN : RemovalPolicy.DESTROY,
    });

    // Dead-letter queue for messages that infra-fail on the worker.
    //
    // The main queue's redrive policy routes messages here after
    // maxReceiveCount=3. Terminal user-facing failures (CompileFailed,
    // InvalidOutputShape, …) are handled inside the worker and NEVER
    // reach the DLQ — only infra flukes (DynamoDB 5xx, malformed
    // record) do.
    //
    // 14-day retention so an operator has time to inspect and replay
    // failed jobs after a multi-day outage. Matches AWS SQS default
    // retention.
    const transformCompileDlq = new sqs.Queue(this, "TransformCompileDLQ", {
      queueName: `transform-compile-dlq-${envName}`,
      retentionPeriod: Duration.days(14),
      removalPolicy: isProd ? RemovalPolicy.RETAIN : RemovalPolicy.DESTROY,
    });

    // Main compile queue.
    //
    // - visibilityTimeout=360s: AWS requires SQS visibility to be >=
    //   the Lambda function timeout for any SQS event source mapping.
    //   Worker function timeout is 300s (fold_db_node/compile_worker
    //   below), so visibility must exceed that. 360s = 300s function
    //   cap + 60s headroom so SQS doesn't redeliver while the worker
    //   is still processing a slow outlier. The original 120s value
    //   from the plan (below function cap) fails CloudFormation with
    //   "Queue visibility timeout X is less than Function timeout Y".
    // - maxReceiveCount=3: two retries after the first delivery.
    //   Third failure routes to DLQ.
    // - Message retention 4 days: generous enough that a weekend-scale
    //   outage doesn't lose in-flight jobs to the queue retention.
    const transformCompileQueue = new sqs.Queue(this, "TransformCompileQueue", {
      queueName: `transform-compile-${envName}`,
      visibilityTimeout: Duration.seconds(360),
      retentionPeriod: Duration.days(4),
      deadLetterQueue: {
        queue: transformCompileDlq,
        maxReceiveCount: 3,
      },
      removalPolicy: isProd ? RemovalPolicy.RETAIN : RemovalPolicy.DESTROY,
    });

    // Request-path Lambda needs to SendMessage to the queue (when
    // POST /v1/transforms enqueues a compile job) and PutItem on the
    // jobs table (for the initial Pending row — the worker later
    // conditionally updates to a terminal status).
    transformCompileQueue.grantSendMessages(schemaServiceFn);
    transformJobsTable.grantReadWriteData(schemaServiceFn);
    schemaServiceFn.addEnvironment(
      "TRANSFORM_COMPILE_QUEUE_URL",
      transformCompileQueue.queueUrl,
    );
    schemaServiceFn.addEnvironment(
      "TRANSFORM_JOBS_TABLE",
      transformJobsTable.tableName,
    );

    // =====================================================
    // Compile worker — DockerImageFunction
    //
    // The worker runs `cargo build --target wasm32-unknown-unknown`
    // on user-submitted Rust source. That requires cargo, rustc, and
    // a prewarmed serde+serde_json registry in the image — which
    // doesn't fit in a Lambda zip. Container images do.
    //
    // Image source: `schema_service/crates/worker/Dockerfile` in the
    // vendored submodule. `lambda.DockerImageCode.fromImageAsset(...)`
    // points at the whole schema_service repo so the Dockerfile's
    // `COPY . .` has access to every crate in the workspace.
    //
    // Memory 4GB + ephemeral 10GB to accommodate cargo builds. Reserved
    // concurrency 5 so a thundering herd of compile requests can't
    // exhaust our AWS account's Lambda pool — compile jobs bucket
    // behind the queue instead.
    // =====================================================
    const compileWorkerFn = new lambda.DockerImageFunction(
      this,
      "TransformCompileWorkerFn",
      {
        functionName: `transform-compile-worker-${envName}`,
        code: lambda.DockerImageCode.fromImageAsset(
          path.join(__dirname, "../../schema_service"),
          {
            file: "crates/worker/Dockerfile",
            // The build.sh pipeline runs the Dockerfile against the
            // whole workspace so the worker crate can resolve its
            // `fold_db = { workspace = ... }` + sibling crate paths.
          },
        ),
        memorySize: 4096,
        ephemeralStorageSize: Size.gibibytes(10),
        timeout: Duration.seconds(300),
        reservedConcurrentExecutions: 5,
        environment: {
          RUST_LOG: "info",
          // Same S3 bucket as the request-path Lambda — the worker
          // writes wasm/{hash}.wasm + source/{hash}.rs + transforms.json
          // atomically there, which the request-path Lambda's later
          // reads see via the shared blob store.
          SCHEMA_STORE_BUCKET: schemaBucket.bucketName,
          TRANSFORM_JOBS_TABLE: transformJobsTable.tableName,
          ANTHROPIC_API_KEY_SECRET_ARN: anthropicApiKey.secretArn,
        },
      },
    );

    // Worker permissions: read/write the schema bucket (wasm + source
    // + transforms.json), write terminal status to the jobs table,
    // read/delete messages on the compile queue, and read the
    // Anthropic API key secret (same classification path as the
    // request-path Lambda).
    schemaBucket.grantReadWrite(compileWorkerFn);
    transformJobsTable.grantReadWriteData(compileWorkerFn);
    anthropicApiKey.grantRead(compileWorkerFn);

    // Wire the queue as an event source. `batchSize=1` because each
    // compile job is heavy-weight; batching would mean a single
    // compile failure redelivers every job in the batch.
    compileWorkerFn.addEventSource(
      new lambdaEventSources.SqsEventSource(transformCompileQueue, {
        batchSize: 1,
        // Don't report individual item failures — the worker handles
        // terminal user-facing outcomes inside and only throws on
        // infra errors, which SQS routes to DLQ via the redrive policy.
        reportBatchItemFailures: false,
      }),
    );

    new CfnOutput(this, "TransformJobsTableName", {
      value: transformJobsTable.tableName,
      description: "DynamoDB table name for async compile job status",
    });
    new CfnOutput(this, "TransformCompileQueueUrl", {
      value: transformCompileQueue.queueUrl,
      description: "SQS queue URL for async compile job messages",
    });
    new CfnOutput(this, "TransformCompileDLQUrl", {
      value: transformCompileDlq.queueUrl,
      description:
        "SQS dead-letter queue URL — messages here need operator attention",
    });
    new CfnOutput(this, "TransformCompileWorkerFunctionName", {
      value: compileWorkerFn.functionName,
      description: "Lambda function name for the async compile worker",
    });

    // =====================================================
    // Custom Domain (schema.folddb.com) — prod only
    // =====================================================
    // WARNING: Do NOT rename the construct IDs below ("SchemaDomainCert",
    // "SchemaDomainName", "SchemaApiMapping"). Changing them causes
    // CloudFormation to delete+recreate the API Gateway domain, which
    // generates a new CNAME target and requires a DNS update.
    if (isProd) {
      const schemaCert = acm.Certificate.fromCertificateArn(
        this,
        "SchemaDomainCert",
        "arn:aws:acm:us-east-1:152335099025:certificate/18c59c49-1581-48b4-ba6c-402bfd3ac2d6",
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
  }
}
