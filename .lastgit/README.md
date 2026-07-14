# LastGit home — schema-infra (GitHub = public mirror)

| Role | Location |
|------|----------|
| **SoT / CR / CI / merge** | `lastdb:///schema-infra` on the **code node** |
| **Public mirror** | `https://github.com/EdgeVector/schema-infra` (browse/clone only) |
| **Deploy gate** | `com.edgevector.lastgit-deploy-schema-infra` |

## Cutover status (2026-07-14 full)

- `.last-stack/pr-venue` = **`lastgit`**
- CI + auto-merge: `com.edgevector.lastgit-forge-code` (concurrency 1, `ci-required`)
- Deploy: `com.edgevector.lastgit-deploy-schema-infra`
- Continuous mirror: `com.edgevector.lastgit-mirror-schema-infra` (install via
  `.lastgit/install-mirror-launchd.sh` from a LastGit main checkout)

## Workflow

```bash
export LASTGIT_SOCKET=$HOME/.lastgit/code/data/folddb.sock
export LASTGIT_SCHEMA_MAP=$HOME/.lastgit/schema-map.json
git config lastgit.socket "$LASTGIT_SOCKET"
git config laststack.pr-venue lastgit

lastgit cr create schema-infra \
  --head <branch> --base main \
  --auto-merge --require-status ci-required
```

GitHub Actions are inert/disabled. Org ruleset still demands a GH `ci-required`
check that Actions no longer emit — **do not open GitHub PRs for merge**.

## Install continuous GitHub mirror

From a checkout of LastGit `main`:

```bash
.lastgit/install-mirror-launchd.sh
.lastgit/sync-github-mirror.sh --once
```

## Pin

```bash
export LASTGIT_SOCKET=$HOME/.lastgit/code/data/folddb.sock
git config lastgit.socket "$LASTGIT_SOCKET"
```
