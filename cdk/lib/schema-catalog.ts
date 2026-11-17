import { Duration } from "aws-cdk-lib";
import * as iam from "aws-cdk-lib/aws-iam";
import * as lambda from "aws-cdk-lib/aws-lambda";
import * as s3 from "aws-cdk-lib/aws-s3";

const PUSHED_PREFIX = "schema-catalog-v2/";

/**
 * Scope the Lambda to the objects that hold pushed schemas.
 *
 * `lastdb app publish` pushes an app's schema definitions to
 * POST /v1/schemas. Nothing here runs on a schedule: the catalog feed that
 * polled the registry lists was removed on 2026-11-17.
 */
export function schemaCatalog(bucket: s3.Bucket, service: lambda.Function): void {
  service.addToRolePolicy(new iam.PolicyStatement({
    actions: ["s3:GetObject", "s3:PutObject"],
    resources: [
      // One record per app and channel, read by advice.
      bucket.arnForObjects(`${PUSHED_PREFIX}catalog.json`),
      // One immutable object per definition id, read by
      // GET /v1/schemas/{definition_id}.
      bucket.arnForObjects(`${PUSHED_PREFIX}definitions/*`),
    ],
  }));
  bucket.addLifecycleRule({
    prefix: PUSHED_PREFIX,
    noncurrentVersionExpiration: Duration.days(7),
  });
}
