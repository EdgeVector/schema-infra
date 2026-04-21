import {
  Stack,
  StackProps,
  Duration,
  CfnOutput,
  RemovalPolicy,
} from "aws-cdk-lib";
import { Construct } from "constructs";
import * as s3 from "aws-cdk-lib/aws-s3";
import * as lambda from "aws-cdk-lib/aws-lambda";
import * as apigwv2 from "aws-cdk-lib/aws-apigatewayv2";
import * as apigwv2Integrations from "aws-cdk-lib/aws-apigatewayv2-integrations";
import * as acm from "aws-cdk-lib/aws-certificatemanager";
import * as secretsmanager from "aws-cdk-lib/aws-secretsmanager";

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
