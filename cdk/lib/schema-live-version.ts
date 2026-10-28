import { Construct } from "constructs";
import * as lambda from "aws-cdk-lib/aws-lambda";

/** CDK publishes a candidate without moving production traffic to it. */
export function schemaLiveVersion(
  scope: Construct,
  fn: lambda.Function,
  isDev: boolean,
): lambda.IVersion {
  if (isDev) return fn.currentVersion;
  const version = scope.node.tryGetContext("schemaProdLiveVersion");
  if (typeof version !== "string" || !/^[1-9][0-9]*$/.test(version)) {
    throw new Error("PROD requires the observed numbered live version; use deploy.sh prod.");
  }
  return lambda.Version.fromVersionArn(
    scope, "PreservedProdLiveVersion", `${fn.functionArn}:${version}`,
  );
}
