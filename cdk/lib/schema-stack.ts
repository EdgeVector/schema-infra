import {
  Stack,
  StackProps,
  Duration,
  CfnOutput,
  RemovalPolicy,
} from "aws-cdk-lib";
import { Construct } from "constructs";
import * as dynamodb from "aws-cdk-lib/aws-dynamodb";
import * as lambda from "aws-cdk-lib/aws-lambda";
import * as apigwv2 from "aws-cdk-lib/aws-apigatewayv2";
import * as apigwv2Integrations from "aws-cdk-lib/aws-apigatewayv2-integrations";
import * as acm from "aws-cdk-lib/aws-certificatemanager";

export interface SchemaServiceStackProps extends StackProps {
  environment?: string; // 'dev' or 'prod'
}

export class SchemaServiceStack extends Stack {
  constructor(scope: Construct, id: string, props?: SchemaServiceStackProps) {
    super(scope, id, props);

    const envName = props?.environment || "dev";
    const isProd = envName === "prod";

    // =====================================================
    // DynamoDB Table for Schema Storage
    // Uses PK (user_id) and SK (schema_name) as key schema
    // to match DynamoDbSchemaStore in fold_db
    // =====================================================
    const schemasTable = new dynamodb.Table(this, "SchemasTable", {
      partitionKey: { name: "PK", type: dynamodb.AttributeType.STRING },
      sortKey: { name: "SK", type: dynamodb.AttributeType.STRING },
      billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
      removalPolicy: RemovalPolicy.RETAIN,
      pointInTimeRecovery: true,
    });

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
        SCHEMAS_TABLE: schemasTable.tableName,
        RUST_LOG: "info",
      },
    });

    // Grant Lambda access to DynamoDB
    schemasTable.grantReadWriteData(schemaServiceFn);

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

    new CfnOutput(this, "SchemasTableName", {
      value: schemasTable.tableName,
      description: "DynamoDB table for schema storage",
    });

    new CfnOutput(this, "SchemaServiceFunctionName", {
      value: schemaServiceFn.functionName,
      description: "Schema service Lambda function name",
    });
  }
}
