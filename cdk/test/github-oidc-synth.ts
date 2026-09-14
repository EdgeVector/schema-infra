import * as assert from "node:assert/strict";
import { App } from "aws-cdk-lib";
import { Template } from "aws-cdk-lib/assertions";
import { SchemaInfraOidcStack } from "../lib/schema-infra-oidc-stack";
import {
  GITHUB_OIDC_AUDIENCE,
  GITHUB_OIDC_ISSUER_HOST,
  GITHUB_OIDC_ISSUER_URL,
} from "../lib/github-oidc";

// The provider and the trust policies are built from named constants now.
// This pins the values those constants must resolve to on the wire: GitHub's
// issuer host and the AWS STS audience. A drift in either (a typo, a
// "helpful" rename) would synthesize cleanly and only fail at the first OIDC
// assume-role in CI, or widen who the role trusts. Fail here instead.
assert.equal(GITHUB_OIDC_ISSUER_HOST, "token.actions.githubusercontent.com");
assert.equal(GITHUB_OIDC_ISSUER_URL, "https://token.actions.githubusercontent.com");
assert.equal(GITHUB_OIDC_AUDIENCE, "sts.amazonaws.com");

const app = new App();
const stack = new SchemaInfraOidcStack(app, "SchemaInfraOidcStack", {
  githubRepo: "EdgeVector/schema-infra",
  env: { account: "000000000000", region: "us-east-1" },
});
const template = Template.fromStack(stack).toJSON() as {
  Resources: Record<
    string,
    {
      Type: string;
      Properties: {
        Url?: string;
        ClientIDList?: string[];
        AssumeRolePolicyDocument?: {
          Statement: Array<{
            Action: string;
            Condition: Record<string, Record<string, string>>;
          }>;
        };
      };
    }
  >;
};

const resources = Object.values(template.Resources);

const providers = resources.filter(
  (resource) => resource.Type === "Custom::AWSCDKOpenIdConnectProvider",
);
assert.equal(providers.length, 1, "exactly one GitHub OIDC provider");
assert.equal(providers[0].Properties.Url, "https://token.actions.githubusercontent.com");
assert.deepStrictEqual(providers[0].Properties.ClientIDList, ["sts.amazonaws.com"]);

// The custom-resource provider's own execution role is assumed by Lambda,
// not by GitHub; only the two deploy roles carry the web-identity policy.
const deployRoles = resources.filter(
  (resource) =>
    resource.Type === "AWS::IAM::Role" &&
    resource.Properties.AssumeRolePolicyDocument?.Statement.some(
      (statement) => statement.Action === "sts:AssumeRoleWithWebIdentity",
    ),
);
assert.equal(deployRoles.length, 2, "dev and prod deploy roles");

const subClaims: string[] = [];
for (const role of deployRoles) {
  const statements = role.Properties.AssumeRolePolicyDocument!.Statement;
  assert.equal(statements.length, 1);
  const [statement] = statements;
  assert.equal(
    statement.Condition.StringEquals["token.actions.githubusercontent.com:aud"],
    "sts.amazonaws.com",
  );
  const sub =
    statement.Condition.StringLike?.["token.actions.githubusercontent.com:sub"] ??
    statement.Condition.StringEquals["token.actions.githubusercontent.com:sub"];
  assert.ok(sub, "every deploy role scopes the sub claim");
  subClaims.push(sub);
}
assert.deepStrictEqual(subClaims.sort(), [
  "repo:EdgeVector/schema-infra:*",
  "repo:EdgeVector/schema-infra:ref:refs/heads/main",
]);

console.log("github-oidc synth test passed (issuer URL, audience, condition keys pinned)");
