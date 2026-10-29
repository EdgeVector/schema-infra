#!/usr/bin/env node
import "source-map-support/register";
import * as cdk from "aws-cdk-lib";
import { SchemaServiceStack } from "../lib/schema-stack";
import { SchemaInfraOidcStack } from "../lib/schema-infra-oidc-stack";
import { Environment } from "../lib/environment";

const app = new cdk.App();

const environment = Environment.fromName(app.node.tryGetContext("environment"));

// An IAM-only release does not need Lambda/model assets or construct a
// service stack. It cannot change a service alias or definition store.
const identityOnly = app.node.tryGetContext("identityOnly") === "true";
if (identityOnly) {
  if (environment.name !== "prod") throw new Error("IAM releases require the explicit prod context");
} else new SchemaServiceStack(app, `SchemaServiceStack-${environment.name}`, {
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
