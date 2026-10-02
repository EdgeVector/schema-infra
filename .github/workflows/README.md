# GitHub workflows

GitHub is the gate of record for this repo since 2026-09-30.

- `ci-required.yml`: the merge gate. Required status check `ci-required`.
  It runs `.lastgit/ci.sh` (shell tests and CDK build and synth tests). It does
  not deploy and has no AWS credentials.
- `deploy.yml`: the deploy over GitHub OIDC (decision
  `decision-2026-09-30-prod-deploy-automation-github-oidc`, prod canary
  `decision-2026-10-01-prod-canary-5pct-24h-soak`). Dev deploys automatically
  after `ci-required` succeeds on a push to main. Prod runs after that dev
  job when dev deploy and dev smoke pass. The prod alias is pinned at 5%
  on the new version. A manual `workflow_dispatch` (target=prod,
  confirm_prod=deploy-prod) runs the same pair. Do not add an `environment:`
  key: it changes the OIDC `sub` claim and the IAM trust rejects it. Roles:
  `SchemaInfraDeployDev`, `SchemaInfraDeployProd` (both trust
  `ref:refs/heads/main` only). Secrets: org `GH_PAT` only.
- `canary-ticker.yml`: every 15 minutes. After 24 hours with the prod alarms
  OK, it promotes the 5% canary to 100%. An ALARM rolls the alias back and
  opens one GitHub issue labeled `schema-canary-rollback`. The runner never
  calls `kanban`. A host-local routine files the card. Do not add an
  `environment:` key.
- `auto-deploy-on-fold.yml`: inert stub. Do not add a fold-triggered deploy
  without Tom.

The old LastGit deploy watcher is not running. `.lastgit/deploy-pipeline.sh`
is the staged pipeline that `deploy.yml` calls. `canary-ticker.yml` runs
`.lastgit/canary-ticker.sh` with `CANARY_STATE_FROM_ALIAS=1`. The live alias
is the soak record.
