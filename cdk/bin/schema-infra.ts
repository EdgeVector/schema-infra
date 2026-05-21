#!/usr/bin/env node
import "source-map-support/register";
import * as cdk from "aws-cdk-lib";
import { SchemaServiceStack } from "../lib/schema-stack";
import { SchemaInfraOidcStack } from "../lib/schema-infra-oidc-stack";

const app = new cdk.App();

// Get environment from context or default to dev
const environment = app.node.tryGetContext("environment") || "dev";

// Determine region based on environment
// Schema service uses us-west-2 for dev, us-east-1 for prod
const region = environment === "prod" ? "us-east-1" : "us-west-2";

new SchemaServiceStack(app, `SchemaServiceStack-${environment}`, {
  environment,
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: region,
  },
  description: `FoldDB Schema Service Infrastructure (${environment})`,
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
