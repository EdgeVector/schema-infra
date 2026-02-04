#!/usr/bin/env node
import "source-map-support/register";
import * as cdk from "aws-cdk-lib";
import { SchemaServiceStack } from "../lib/schema-stack";

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
