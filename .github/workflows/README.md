# GitHub workflows

GitHub is the gate of record for this repo since 2026-09-30.

- `ci-required.yml`: the merge gate. Required status check `ci-required`.
  It runs `.lastgit/ci.sh` (shell tests and CDK build and synth tests). It does
  not deploy and has no AWS credentials.
- `deploy.yml` and `auto-deploy-on-fold.yml`: inert stubs. They are
  `workflow_dispatch` only and do nothing. This repo deploys to AWS prod.
  Do not add push, schedule, or fold-triggered deploy triggers without Tom.

The old LastGit deploy pipeline (`.lastgit/deploy-*`, canary ticker) is not
running. Deploy automation is off until Tom chooses a GitHub-keyed replacement.
