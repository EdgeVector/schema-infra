import * as assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { App } from "aws-cdk-lib";
import { Template } from "aws-cdk-lib/assertions";
import { SchemaServiceStack } from "../lib/schema-stack";

// The stack needs Lambda and layer assets during synthesis. The alarm test
// only checks the synthesized CloudWatch contract, so a small fixture is
// sufficient and keeps the test independent of a built Lambda.
const root = fs.mkdtempSync(path.join(os.tmpdir(), "schema-infra-synth-"));
const lambdaDir = path.join(root, "fold/target/lambda/server_lambda-extracted");
const layerDir = path.join(root, "target/fastembed_layer");
fs.mkdirSync(lambdaDir, { recursive: true });
fs.mkdirSync(layerDir, { recursive: true });
fs.writeFileSync(path.join(lambdaDir, "bootstrap"), "synth-fixture\n");
fs.writeFileSync(path.join(layerDir, "README"), "synth-fixture\n");
const cdkDir = path.join(root, "cdk");
fs.mkdirSync(cdkDir);
const previousCwd = process.cwd();
process.chdir(cdkDir);

try {
  const app = new App({ outdir: path.join(root, "cdk.out") });
  const stack = new SchemaServiceStack(app, "SchemaServiceStack-prod", {
    environment: "prod",
    env: { account: "000000000000", region: "us-east-1" },
  });
  const template = Template.fromStack(stack).toJSON() as {
    Resources: Record<
      string,
      {
        Type: string;
        Properties?: {
          AlarmName?: string;
          Threshold?: number;
          EvaluationPeriods?: number;
          DatapointsToAlarm?: number;
          Metrics?: Array<{
            Id?: string;
            Expression?: string;
            MetricStat?: { Metric?: { MetricName?: string } };
          }>;
        };
      }
    >;
  };
  const alarm = Object.values(template.Resources).find(
    (resource) =>
      resource.Type === "AWS::CloudWatch::Alarm" &&
      resource.Properties?.AlarmName === "schema-mutation-gate-hourly-quota-prod",
  );
  assert.ok(alarm, "the production hourly quota alarm is synthesized");
  assert.equal(alarm.Properties?.Threshold, 5);
  assert.equal(alarm.Properties?.EvaluationPeriods, 3);
  assert.equal(alarm.Properties?.DatapointsToAlarm, 3);
  assert.deepEqual(alarm.Properties?.Metrics, [
    { Expression: "q", Id: "expr_1", Label: "hourly cap rejects", ReturnData: true },
    {
      Id: "q",
      Label: "quota rejections",
      MetricStat: {
        Metric: { MetricName: "RejectQuotaExceeded", Namespace: "SchemaService/MutationGate" },
        Period: 3600,
        Stat: "Sum",
      },
      ReturnData: false,
    },
  ]);
} finally {
  process.chdir(previousCwd);
  fs.rmSync(root, { recursive: true, force: true });
}

console.log("ok mutation-gate-quota-alarm-synth");
