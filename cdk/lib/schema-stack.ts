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
    // Schema Service Lambda Function
    // =====================================================
    const schemaServiceFn = new lambda.Function(this, "SchemaServiceFn", {
      runtime: lambda.Runtime.PROVIDED_AL2023,
      handler: "bootstrap",
      code: lambda.Code.fromAsset(
        "../lambdas/schema_service/target/lambda/schema_service-extracted",
      ),
      timeout: Duration.seconds(30),
      memorySize: 256,
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

    // REST API endpoints
    httpApi.addRoutes({
      path: "/api/schemas",
      methods: [apigwv2.HttpMethod.GET, apigwv2.HttpMethod.POST],
      integration: new apigwv2Integrations.HttpLambdaIntegration(
        "SchemaListIntegration",
        schemaServiceFn,
      ),
    });

    httpApi.addRoutes({
      path: "/api/schemas/available",
      methods: [apigwv2.HttpMethod.GET],
      integration: new apigwv2Integrations.HttpLambdaIntegration(
        "SchemaAvailableIntegration",
        schemaServiceFn,
      ),
    });

    httpApi.addRoutes({
      path: "/api/schemas/similar/{schemaId}",
      methods: [apigwv2.HttpMethod.GET],
      integration: new apigwv2Integrations.HttpLambdaIntegration(
        "SchemaSimilarIntegration",
        schemaServiceFn,
      ),
    });

    httpApi.addRoutes({
      path: "/api/schemas/{schemaId}",
      methods: [apigwv2.HttpMethod.GET],
      integration: new apigwv2Integrations.HttpLambdaIntegration(
        "SchemaGetIntegration",
        schemaServiceFn,
      ),
    });

    // Support singular /api/schema/{schemaId} used by FoldDB client
    httpApi.addRoutes({
      path: "/api/schema/{schemaId}",
      methods: [apigwv2.HttpMethod.GET],
      integration: new apigwv2Integrations.HttpLambdaIntegration(
        "SchemaGetSingularIntegration",
        schemaServiceFn,
      ),
    });

    // View endpoints
    httpApi.addRoutes({
      path: "/api/views",
      methods: [apigwv2.HttpMethod.GET, apigwv2.HttpMethod.POST],
      integration: new apigwv2Integrations.HttpLambdaIntegration(
        "ViewListIntegration",
        schemaServiceFn,
      ),
    });

    httpApi.addRoutes({
      path: "/api/views/available",
      methods: [apigwv2.HttpMethod.GET],
      integration: new apigwv2Integrations.HttpLambdaIntegration(
        "ViewAvailableIntegration",
        schemaServiceFn,
      ),
    });

    httpApi.addRoutes({
      path: "/api/view/{viewId}",
      methods: [apigwv2.HttpMethod.GET],
      integration: new apigwv2Integrations.HttpLambdaIntegration(
        "ViewGetIntegration",
        schemaServiceFn,
      ),
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
