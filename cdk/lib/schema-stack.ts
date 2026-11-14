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
import * as cloudwatch from "aws-cdk-lib/aws-cloudwatch";
import * as dynamodb from "aws-cdk-lib/aws-dynamodb";
import { Environment } from "./environment";
import { schemaLiveVersion } from "./schema-live-version";

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
    const definitionNamespace = "canonical-v2";

    // Backend Sentry config, added to the request-path Lambda. Prod deploy.sh
    // loads OBS_SENTRY_DSN with `gh variable get` (echo off) and exports it
    // only for this synth so it lands in the Lambda environment. Empty when
    // the get fails or the variable is unset — no Sentry project is created
    // here, and no DSN is invented. `observability::init_lambda` then leaves
    // the Sentry sink off and CloudWatch logging is unchanged.
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
    // Retained S3 Bucket (historical Schema Service state)
    //
    // The advisory Lambda is stateless and reads its canonical vocabulary
    // from compile-time `builtin_canonical_fields.json`, with no S3 grant or
    // runtime bucket env var. This retained bucket stays in the stack so
    // CloudFormation never orphans or alters existing versioned objects or
    // external stack-output readers.
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
    // Schema Service Lambda Function
    // =====================================================
    // Stateless deterministic advisory service built from `fold/`
    // (`schema_service/crates/server_lambda`). `build.sh` compiles the
    // AL2023 x86_64 zip and extracts it to `server_lambda-extracted`.
    const schemaServiceFn = new lambda.Function(this, "SchemaServiceFn", {
      runtime: lambda.Runtime.PROVIDED_AL2023,
      architecture: lambda.Architecture.X86_64,
      handler: "bootstrap",
      code: lambda.Code.fromAsset(
        "../fold/target/lambda/server_lambda-extracted",
      ),
      // Keep every published version when CDK replaces `currentVersion`.
      // Without this, CloudFormation deletes the previous version at the
      // end of each deploy (the default DeletionPolicy for
      // AWS::Lambda::Version is Delete). That deleted the pre-deploy live
      // version (prod v32, 2026-09-23), so the canary pin had no rollback
      // target. The canary (scripts/deploy/canary-lib.sh) weights the new
      // version against the pre-deploy live version, and that version
      // must still exist after CDK runs.
      //
      // CAUTION: CloudFormation applies the DeletionPolicy of the template
      // that is live when a resource leaves the stack. The first deploy
      // of this change still deletes the version that the previous template
      // owned; every later deploy retains it.
      currentVersionOptions: {
        removalPolicy: RemovalPolicy.RETAIN,
      },
      timeout: Duration.seconds(300),
      memorySize: 512,
      environment: {
        RUST_LOG: "info",
        OBS_SENTRY_DSN: obsSentryDsn,
        OBS_SENTRY_RELEASE: obsSentryRelease,
        OBS_SENTRY_ENVIRONMENT: obsSentryEnvironment,
        ENVIRONMENT: envName,
      },
    });

    // Production keeps its observed live version throughout CDK deployment.
    // Only the checked canary path may route traffic to the published candidate.
    const schemaServiceLive = new lambda.Alias(this, "SchemaServiceLiveAlias", {
      aliasName: "live",
      version: schemaLiveVersion(this, schemaServiceFn, environment.isDev),
    });
    new CfnOutput(this, "SchemaServiceCandidateVersion", {
      value: schemaServiceFn.currentVersion.version,
      description: "Published candidate; production traffic stays on the preserved live version",
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
        allowOrigins: environment.schemaHttpApiCorsAllowOrigins,
        allowMethods: [
          apigwv2.CorsHttpMethod.GET,
          apigwv2.CorsHttpMethod.POST,
          apigwv2.CorsHttpMethod.OPTIONS,
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
    // Advice is read-only but walks the whole vocabulary for each field, so it
    // gets its own lower limit. An HTTP API has no per-caller limit without
    // WAF; this route limit keeps advice from crowding out the read routes.
    //
    // CfnStage.routeSettings is raw JSON: CDK passes the keys through
    // unchanged, and CloudFormation accepts only the PascalCase names
    // (defaultRouteSettings above is typed, so CDK renames its keys). The
    // camelCase form failed the dev stack update with `Unrecognized field
    // "throttlingBurstLimit"`.
    stage.routeSettings = {
      "POST /v1/advice/schema": {
        ThrottlingBurstLimit: 20,
        ThrottlingRateLimit: 10,
      },
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
    // Route definitions — advisory /v1 surface only.
    //
    // Keep only the advisory endpoints actually served by
    // schema_service/crates/server_lambda/src/dispatch.rs:
    //   GET  /v1/health
    //   GET  /v1/fields/vocabulary
    //   POST /v1/advice/schema
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
        // Advice for one draft schema declaration. Read-only; it never
        // blocks a declare (design-lastdb-advisory-schema-service).
        path: "/v1/advice/schema",
        methods: [apigwv2.HttpMethod.POST],
        integrationId: "SchemaAdviceIntegrationV1",
      },
      {
        path: "/v1/fields/vocabulary",
        methods: [apigwv2.HttpMethod.GET],
        integrationId: "CanonicalVocabularyIntegrationV1",
      },
    ];

    for (const route of v1Routes) {
      const added = httpApi.addRoutes({
        path: route.path,
        methods: route.methods,
        integration: lambdaIntegration(route.integrationId),
      });
      // The stage's route settings reference this route by key.
      if (route.path === "/v1/advice/schema") {
        added.forEach((throttledRoute) => stage.node.addDependency(throttledRoute));
      }
    }

    // =====================================================
    // Retained DynamoDB embeddings table (historical state)
    //
    // Retained in the stack so CloudFormation preserves the live table;
    // the stateless advisory Lambda neither reads nor writes it.
    // =====================================================
    new dynamodb.Table(this, "AtomicVocabularyEmbeddingsTable", {
      tableName: `schema-embeddings-${envName}-${definitionNamespace}`,
      partitionKey: { name: "kind", type: dynamodb.AttributeType.STRING },
      sortKey: { name: "key", type: dynamodb.AttributeType.STRING },
      billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
      removalPolicy: RemovalPolicy.RETAIN,
    });

    // =====================================================
    // Canary & Service Health CloudWatch Alarms
    // =====================================================
    const lambdaErrorsAlarm = new cloudwatch.Alarm(
      this,
      "SchemaServiceLambdaErrorsAlarm",
      {
        alarmName: `schema-service-lambda-errors-${envName}`,
        alarmDescription:
          "Schema Service Lambda reported >= 1 invocation error in 5 minutes; blocks canary promotion and triggers rollback.",
        metric: schemaServiceFn.metricErrors({
          period: Duration.minutes(5),
          statistic: "Sum",
        }),
        threshold: 1,
        evaluationPeriods: 1,
        datapointsToAlarm: 1,
        comparisonOperator:
          cloudwatch.ComparisonOperator.GREATER_THAN_OR_EQUAL_TO_THRESHOLD,
        treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
      },
    );

    const http5xxAlarm = new cloudwatch.Alarm(
      this,
      "SchemaServiceHttp5xxAlarm",
      {
        alarmName: `schema-service-http-5xx-${envName}`,
        alarmDescription:
          "Schema Service HTTP API returned >= 1 5xx response in 5 minutes; blocks canary promotion and triggers rollback.",
        metric: new cloudwatch.Metric({
          namespace: "AWS/ApiGateway",
          metricName: "5xx",
          dimensionsMap: {
            ApiId: httpApi.apiId,
          },
          period: Duration.minutes(5),
          statistic: "Sum",
        }),
        threshold: 1,
        evaluationPeriods: 1,
        datapointsToAlarm: 1,
        comparisonOperator:
          cloudwatch.ComparisonOperator.GREATER_THAN_OR_EQUAL_TO_THRESHOLD,
        treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
      },
    );

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
      description: "S3 bucket retained from historical schema service state",
    });

    new CfnOutput(this, "SchemaServiceFunctionName", {
      value: schemaServiceFn.functionName,
      description: "Schema service Lambda function name",
    });

    new CfnOutput(this, "SchemaServiceLiveAliasName", {
      value: schemaServiceLive.functionName,
      description: "Qualified live alias name (function:live) for canary traffic",
    });

    new CfnOutput(this, "SchemaServiceLambdaErrorsAlarmName", {
      value: lambdaErrorsAlarm.alarmName,
      description: "Alarm on Schema Service Lambda invocation errors",
    });

    new CfnOutput(this, "SchemaServiceHttp5xxAlarmName", {
      value: http5xxAlarm.alarmName,
      description: "Alarm on Schema Service HTTP API 5xx responses",
    });
  }
}
