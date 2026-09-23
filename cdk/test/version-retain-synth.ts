import * as assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { App } from "aws-cdk-lib";
import { Template } from "aws-cdk-lib/assertions";
import { SchemaServiceStack } from "../lib/schema-stack";

// The staged canary weights a new Lambda version against the version that
// was live before the deploy, and the ticker rolls back to it on ALARM. That
// only works if CloudFormation keeps the old version when CDK replaces
// `currentVersion`. On 2026-09-23 CloudFormation deleted prod v32 (and dev
// v41-v46), and the canary fell back to a 2026-09-01 version as primary.
// Pin DeletionPolicy/UpdateReplacePolicy = Retain on every Lambda version, and
// keep the `live` alias on that version, so a refactor cannot drop it again.

// The stack reads two asset directories relative to the process cwd
// (../fold/target/lambda/server_lambda-extracted and ../target/fastembed_layer).
// CI clones do not build the Lambda, so synth against a throwaway tree.
const root = fs.mkdtempSync(path.join(os.tmpdir(), "schema-infra-synth-"));
const lambdaDir = path.join(root, "fold/target/lambda/server_lambda-extracted");
const layerDir = path.join(root, "target/fastembed_layer");
fs.mkdirSync(lambdaDir, { recursive: true });
fs.mkdirSync(layerDir, { recursive: true });
fs.writeFileSync(path.join(lambdaDir, "bootstrap"), "synth-fixture\n");
fs.writeFileSync(path.join(layerDir, "README"), "synth-fixture\n");
const cdkDir = path.join(root, "cdk");
fs.mkdirSync(cdkDir);
const prevCwd = process.cwd();
process.chdir(cdkDir);

try {
  for (const envName of ["dev", "prod"]) {
    const app = new App({ outdir: path.join(root, `cdk.out-${envName}`) });
    const stack = new SchemaServiceStack(app, `SchemaServiceStack-${envName}`, {
      environment: envName,
      env: { account: "000000000000", region: envName === "prod" ? "us-east-1" : "us-west-2" },
    });
    const template = Template.fromStack(stack).toJSON() as {
      Resources: Record<
        string,
        {
          Type: string;
          DeletionPolicy?: string;
          UpdateReplacePolicy?: string;
          Properties?: { FunctionVersion?: unknown; Name?: string };
        }
      >;
    };
    const entries = Object.entries(template.Resources);
    const versions = entries.filter(([, r]) => r.Type === "AWS::Lambda::Version");
    assert.ok(versions.length >= 1, `${envName}: expected a Lambda version resource`);
    for (const [id, r] of versions) {
      assert.equal(r.DeletionPolicy, "Retain", `${envName}: ${id} DeletionPolicy must be Retain`);
      assert.equal(
        r.UpdateReplacePolicy,
        "Retain",
        `${envName}: ${id} UpdateReplacePolicy must be Retain`,
      );
    }
    const liveAliases = entries.filter(
      ([, r]) => r.Type === "AWS::Lambda::Alias" && r.Properties?.Name === "live",
    );
    assert.equal(liveAliases.length, 1, `${envName}: exactly one live alias`);
    const fv = JSON.stringify(liveAliases[0][1].Properties?.FunctionVersion);
    assert.ok(
      versions.some(([id]) => fv.includes(id)),
      `${envName}: live alias must point at the retained version resource, got ${fv}`,
    );
  }
} finally {
  process.chdir(prevCwd);
  fs.rmSync(root, { recursive: true, force: true });
}

console.log("ok version-retain-synth");
