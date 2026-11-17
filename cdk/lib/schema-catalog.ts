import { Duration } from "aws-cdk-lib";
import * as cloudwatch from "aws-cdk-lib/aws-cloudwatch";
import * as events from "aws-cdk-lib/aws-events";
import * as targets from "aws-cdk-lib/aws-events-targets";
import * as iam from "aws-cdk-lib/aws-iam";
import * as lambda from "aws-cdk-lib/aws-lambda";
import * as logs from "aws-cdk-lib/aws-logs";
import * as s3 from "aws-cdk-lib/aws-s3";
import { Construct } from "constructs";

const CATALOG_PREFIX = "advisory-catalog-v1/";
const PUSHED_PREFIX = "schema-catalog-v2/";
const FEED_PATH = "/v1/internal/catalog-feed";

/** Schedule the code on the normal alias and scope access to the catalog image. */
export function schemaCatalog(
  scope: Construct,
  bucket: s3.Bucket,
  service: lambda.Function,
  live: lambda.Alias,
  environment: string,
): void {
  service.addToRolePolicy(new iam.PolicyStatement({
    actions: ["s3:GetObject", "s3:PutObject"],
    resources: [
      bucket.arnForObjects(`${CATALOG_PREFIX}catalog.json`),
      // Pushed schemas (POST /v1/schemas) live here. The feed image above
      // goes away with the feed once the push code is fully live.
      bucket.arnForObjects(`${PUSHED_PREFIX}catalog.json`),
    ],
  }));
  for (const prefix of [CATALOG_PREFIX, PUSHED_PREFIX]) {
    bucket.addLifecycleRule({
      prefix,
      noncurrentVersionExpiration: Duration.days(7),
    });
  }

  new events.Rule(scope, "SchemaCatalogFeedSchedule", {
    description: "Refreshes the advisory catalog from signed public app registry lists",
    schedule: events.Schedule.rate(Duration.minutes(5)),
    targets: [new targets.LambdaFunction(live, {
      retryAttempts: 0,
      maxEventAge: Duration.minutes(4),
      // This path is deliberately absent from API Gateway. Only a direct
      // invocation with the schedule's API ID can enter the feed handler.
      event: events.RuleTargetInput.fromObject({
        version: "2.0",
        routeKey: `POST ${FEED_PATH}`,
        rawPath: FEED_PATH,
        rawQueryString: "",
        headers: { host: "schema-catalog-feed.invalid" },
        requestContext: {
          apiId: "catalog-feed-schedule",
          requestId: events.EventField.eventId,
          routeKey: `POST ${FEED_PATH}`,
          stage: "$default",
          http: {
            method: "POST",
            path: FEED_PATH,
            protocol: "HTTP/1.1",
            sourceIp: "127.0.0.1",
            userAgent: "schema-catalog-feed-schedule",
          },
        },
        isBase64Encoded: false,
      }),
    })],
  });

  const logGroup = logs.LogGroup.fromLogGroupName(
    scope, "SchemaCatalogServiceLogGroup", `/aws/lambda/${service.functionName}`,
  );
  const failures = new logs.MetricFilter(scope, "SchemaCatalogFeedFailures", {
    logGroup,
    filterPattern: logs.FilterPattern.allTerms("schema_catalog_feed_failure"),
    metricNamespace: "LastDB/SchemaService",
    metricName: `CatalogFeedFailure-${environment}`,
    metricValue: "1",
  });
  new cloudwatch.Alarm(scope, "SchemaCatalogFeedFailureAlarm", {
    alarmName: `schema-service-catalog-feed-failures-${environment}`,
    alarmDescription: "The registry catalog refresh reported a failure in three five-minute periods.",
    metric: failures.metric({ period: Duration.minutes(5), statistic: "Sum" }),
    threshold: 1,
    evaluationPeriods: 3,
    datapointsToAlarm: 3,
    comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_OR_EQUAL_TO_THRESHOLD,
    treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
  });
}
