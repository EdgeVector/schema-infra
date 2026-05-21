import { Stack, StackProps, CfnOutput } from "aws-cdk-lib";
import { Construct } from "constructs";
import * as iam from "aws-cdk-lib/aws-iam";

export interface SchemaInfraOidcStackProps extends StackProps {
  // Owner/repo string GitHub embeds in OIDC `sub` claims. e.g.
  // "EdgeVector/schema-infra".
  githubRepo: string;
}

// Account-global IAM resources that let GitHub Actions in
// `EdgeVector/schema-infra` deploy to AWS via OIDC instead of long-lived
// static access keys. Deployed once (us-east-1 is fine — IAM is global)
// before the workflow flips to OIDC; not deployed by deploy.yml itself.
//
// Two roles, scoped via OIDC `sub` claim:
//   SchemaInfraDeployDev  — any ref, can only touch the us-west-2 CDK
//                           bootstrap roles and describe SchemaServiceStack-dev.
//   SchemaInfraDeployProd — refs/heads/main only, can only touch the
//                           us-east-1 CDK bootstrap roles and describe
//                           SchemaServiceStack-prod.
export class SchemaInfraOidcStack extends Stack {
  constructor(scope: Construct, id: string, props: SchemaInfraOidcStackProps) {
    super(scope, id, props);

    const provider = new iam.OpenIdConnectProvider(this, "GitHubOidcProvider", {
      url: "https://token.actions.githubusercontent.com",
      clientIds: ["sts.amazonaws.com"],
    });

    const account = Stack.of(this).account;
    const cdkBootstrapRoleArns = (region: string) => [
      `arn:aws:iam::${account}:role/cdk-hnb659fds-deploy-role-${account}-${region}`,
      `arn:aws:iam::${account}:role/cdk-hnb659fds-file-publishing-role-${account}-${region}`,
      `arn:aws:iam::${account}:role/cdk-hnb659fds-image-publishing-role-${account}-${region}`,
      `arn:aws:iam::${account}:role/cdk-hnb659fds-lookup-role-${account}-${region}`,
    ];

    const buildRole = (
      roleId: string,
      roleName: string,
      subCondition: { test: "StringEquals" | "StringLike"; value: string },
      region: string,
      stackName: string,
    ): iam.Role => {
      const conditions: Record<string, Record<string, string>> = {
        StringEquals: {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
        },
      };
      conditions[subCondition.test] = {
        ...(conditions[subCondition.test] ?? {}),
        "token.actions.githubusercontent.com:sub": subCondition.value,
      };

      const role = new iam.Role(this, roleId, {
        roleName,
        assumedBy: new iam.FederatedPrincipal(
          provider.openIdConnectProviderArn,
          conditions,
          "sts:AssumeRoleWithWebIdentity",
        ),
        description: `GitHub Actions OIDC role for ${props.githubRepo} (${region})`,
      });

      role.addToPolicy(
        new iam.PolicyStatement({
          sid: "AssumeCdkBootstrapRoles",
          actions: ["sts:AssumeRole"],
          resources: cdkBootstrapRoleArns(region),
        }),
      );

      // The deploy workflow's post-deploy step calls `aws cloudformation
      // describe-stacks` directly (not through cdk), so the OIDC role
      // itself needs that permission scoped to the relevant stack.
      role.addToPolicy(
        new iam.PolicyStatement({
          sid: "ReadStackOutputs",
          actions: ["cloudformation:DescribeStacks"],
          resources: [
            `arn:aws:cloudformation:${region}:${account}:stack/${stackName}/*`,
          ],
        }),
      );

      return role;
    };

    const devRole = buildRole(
      "DeployDevRole",
      "SchemaInfraDeployDev",
      // Dev is intentionally lax — workflow_dispatch on feature branches
      // deploys to dev for testing, which today works and we preserve.
      { test: "StringLike", value: `repo:${props.githubRepo}:*` },
      "us-west-2",
      "SchemaServiceStack-dev",
    );

    const prodRole = buildRole(
      "DeployProdRole",
      "SchemaInfraDeployProd",
      // Prod is locked to main. deploy.yml's `if: github.ref ==
      // 'refs/heads/main'` is belt; this OIDC condition is suspenders —
      // a future workflow edit that removed the gate still couldn't
      // assume this role from a feature branch.
      {
        test: "StringEquals",
        value: `repo:${props.githubRepo}:ref:refs/heads/main`,
      },
      "us-east-1",
      "SchemaServiceStack-prod",
    );

    new CfnOutput(this, "DeployDevRoleArn", {
      value: devRole.roleArn,
      description: "ARN to wire into deploy.yml's deploy-dev job (role-to-assume)",
    });
    new CfnOutput(this, "DeployProdRoleArn", {
      value: prodRole.roleArn,
      description: "ARN to wire into deploy.yml's deploy-prod job (role-to-assume)",
    });
    new CfnOutput(this, "GitHubOidcProviderArn", {
      value: provider.openIdConnectProviderArn,
      description: "Account-wide GitHub Actions OIDC provider ARN",
    });
  }
}
