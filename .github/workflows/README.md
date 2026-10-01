# GitHub workflows

GitHub is the gate of record for this repo since 2026-09-30.

- `ci-required.yml`: the merge gate. Required status check `ci-required`.
  It runs `.lastgit/ci.sh` (shell tests and CDK build and synth tests). It does
  not deploy and has no AWS credentials.
- `deploy.yml`: the deploy over GitHub OIDC (decision
  `decision-2026-09-30-prod-deploy-automation-github-oidc`). Dev deploys
  automatically after `ci-required` succeeds on a push to main. Prod runs only
  from a manual `workflow_dispatch` (target=prod, confirm_prod=deploy-prod).
  Do not add an `environment:` key: it changes the OIDC `sub` claim and the
  IAM trust rejects it. Roles: `SchemaInfraDeployDev`, `SchemaInfraDeployProd`
  (both trust `ref:refs/heads/main` only). Secrets: org `GH_PAT` only.
- `auto-deploy-on-fold.yml`: inert stub. Do not add a fold-triggered deploy
  without Tom.

The old LastGit deploy watcher and canary ticker (`.lastgit/deploy-run.sh`,
`.lastgit/canary-ticker.sh`) are not running. `.lastgit/deploy-pipeline.sh` is
the staged pipeline that `deploy.yml` calls. Canary soak state is still a local
file, so the GitHub prod job keeps the 10% pin and a human promotes or rolls
back. Follow-up: SSM canary state and a ticker workflow.
