# GitHub workflows

GitHub is the gate of record for this repo since 2026-09-30.

## Deploy on merge

Tom set this flow on 2026-10-31: a Schema Service change deploys on merge, to DEV first and then to PROD.

1. A PR merges in `EdgeVector/lastdb`. When it changes a Schema Service Lambda input, lastdb
   `notify-schema-infra.yml` sends the `lastdb-schema-service-changed` repository dispatch here.
2. `auto-deploy-on-fold.yml` runs `scripts/deploy/fold-bump.sh`. The script compares the `fold` pin
   with lastdb main. It opens one PR only when a path in `scripts/deploy/fold-lambda-inputs.txt`
   changed. The PR changes only the gitlink. Auto-merge (squash) is on. A 30-minute schedule
   catches a missed dispatch.
3. The merge runs `ci-required` on main. Then `deploy.yml` deploys DEV and runs the DEV smoke check.
4. When the DEV smoke check passes and `canonical-vocabulary/phase` is `prod`, the prod job pins 5%
   of the live alias on the new version.
5. `canary-ticker.yml` promotes the canary after 24 hours with alarms OK. An ALARM rolls it back.

A canary that still soaks keeps its full 24 hours. A newer release does not replace it. The prod job
changes nothing, records `prod deferred: canary soaking`, and succeeds. After the promotion, the
ticker runs `scripts/deploy/prod-catch-up.sh`. That script starts one `deploy.yml` run with
`target=prod` when the alias has no canary and PROD is behind main. That run deploys DEV again,
smokes DEV, and pins the next 5% canary. The order stays: DEV deploy, DEV smoke, PROD 5% pin,
24-hour soak, promotion.

The catch-up starts nothing in these conditions:

- `canonical-vocabulary/phase` is not `prod`.
- An issue labeled `schema-canary-rollback` is open. A person reviews the rollback and closes the issue.
- A `deploy.yml` run is queued or running.
- The newest finished `deploy.yml` run on main failed. A new main push or a person starts the next run.
- PROD is current with main.
- The newest `ci-required` run for the main revision did not pass.

The catch-up passes that exact revision to `deploy.yml`. Every `workflow_dispatch` of `deploy.yml`
checks that its revision is on main and that its newest `ci-required` run passed.

A person can close a bump PR to stop that lastdb revision. The next lastdb change opens a new bump PR.
If lastdb main does not contain the pin, `auto-deploy-on-fold.yml` fails. A person must check the pin.

## Workflows

- `ci-required.yml`: the merge gate. Required status check `ci-required`.
  It runs `.lastgit/ci.sh` (shell and Python syntax checks and CDK build). Tests are
  deleted (2026-10-09). It does not deploy and has no AWS credentials.
- `auto-deploy-on-fold.yml`: moves the `fold` pin (see above). It uses the org
  `GH_PAT`, because a PR that `GITHUB_TOKEN` opens does not start the required checks.
  It has no AWS credentials.
- `deploy.yml`: the deploy over GitHub OIDC (decision
  `decision-2026-09-30-prod-deploy-automation-github-oidc`, prod canary
  `decision-2026-10-01-prod-canary-5pct-24h-soak`). Dev deploys automatically
  after `ci-required` succeeds on a push to main. Prod runs after that dev
  job when dev deploy and dev smoke pass and `canonical-vocabulary/phase` is `prod`.
  The `dev` phase keeps PROD on its current binary. A reviewed source change opens PROD after real DEV operations.
  A manual or catch-up `workflow_dispatch` (target=prod, confirm_prod=deploy-prod) runs the same pair.
  In that run the dev job classifies against the PROD base. Do not add an `environment:`
  key: it changes the OIDC `sub` claim and the IAM trust rejects it. Roles:
  `SchemaInfraDeployDev`, `SchemaInfraDeployProd` (both trust
  `ref:refs/heads/main` only). Secrets: org `GH_PAT` only. Optional
  repository variable `OBS_SENTRY_DSN`: `deploy.sh` reads it with
  `gh variable get` on prod and never prints it. Do not map it in a
  step `env:` block. Do not invent a DSN. No Sentry project exists yet.
- `canary-ticker.yml`: every 15 minutes. After 24 hours with the prod alarms
  OK, it promotes the 5% canary to 100%. An ALARM rolls the alias back and
  opens one GitHub issue labeled `schema-canary-rollback`. Then it runs the PROD
  catch-up. The runner never calls `kanban`. A host-local routine files the card.
  Do not add an `environment:` key.
- `prepare-prod.yml`: manual accepted-main preparation for the approved definition retirement.
  It requires current main CI and CodeQL, deploys the reviewed qualified-read IAM permission,
  builds the core in CI, and checks a separate numbered PROD candidate.
  It preserves the public version and does not open the PROD phase or start a canary.
  The next reviewed source change controls the atomic store reset and the ordinary release.

The old LastGit deploy watcher is not running. `.lastgit/deploy-pipeline.sh`
is the staged pipeline that `deploy.yml` calls. `canary-ticker.yml` runs
`.lastgit/canary-ticker.sh` with `CANARY_STATE_FROM_ALIAS=1`. The live alias
is the soak record.
