#!/usr/bin/env node
import "source-map-support/register";
import * as cdk from "aws-cdk-lib";
import { SchemaServiceStack } from "../lib/schema-stack";
import { SchemaInfraOidcStack } from "../lib/schema-infra-oidc-stack";
import { Environment } from "../lib/environment";

const app = new cdk.App();

const environment = Environment.fromName(app.node.tryGetContext("environment"));

new SchemaServiceStack(app, `SchemaServiceStack-${environment.name}`, {
  environment: environment.name,
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: environment.region,
  },
  description: `FoldDB Schema Service Infrastructure (${environment.name})`,
});

// Account-global IAM stack for the GitHub Actions OIDC provider + the
// two deploy roles. Pinned to us-east-1 (IAM is global; the region only
// determines where the CloudFormation stack itself lives). Deployed
// manually with current credentials before flipping the workflows over
// to OIDC; deploy.yml does NOT deploy this stack.
new SchemaInfraOidcStack(app, "SchemaInfraOidcStack", {
  githubRepo: "EdgeVector/schema-infra",
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: "us-east-1",
  },
  description: "GitHub Actions OIDC provider + deploy roles for schema-infra",
});
