# LastGit home — schema-infra (GitHub = public mirror)

| Role | Location |
|------|----------|
| **SoT / CR / CI / merge** | `lastdb:///schema-infra` on the primary Mini |
| **Public mirror** | `https://github.com/EdgeVector/schema-infra` (browse/clone only) |
| **Deploy gate** | `com.edgevector.lastgit-deploy-schema-infra` |

## Cutover status (2026-07-15 primary Mini)

- `.last-stack/pr-venue` = **`lastgit`**
- CI + auto-merge: `com.edgevector.lastgit-forge-primary` (concurrency 1, `ci-required`)
- Deploy: `com.edgevector.lastgit-deploy-schema-infra`
- Reinstall deploy supervisor from a LastGit main checkout with
  `.lastgit/install-deploy-launchd.sh`; it copies `.lastgit/deploy-run.sh` into
  `$HOME/.lastgit/deploy-schema-infra/deploy-run.sh` and points launchd at that
  durable copy.
- Continuous mirror: `com.edgevector.lastgit-mirror-schema-infra` (install via
  `.lastgit/install-mirror-launchd.sh` from a LastGit main checkout)
- Socket: `$HOME/.lastdb/data/folddb.sock`

The retired code-node path under `$HOME/.lastgit/code` must not be used for
daily-driver CR, CI, or deploy status. Deploy launchd jobs pin
`LASTGIT_SOCKET` in `.lastgit/deploy-run.sh` so `deploy-pipeline` status is
published to the same primary Mini node as CR merge state.

Deploy launchd must point at a durable checkout, normally
`$HOME/.lastgit/mirror-clones/schema-infra`, not a one-shot ship checkout. Run
`.lastgit/install-deploy-launchd.sh install` after deploy runner changes so the
LaunchAgent cannot keep supervising a deleted or stale checkout.

Canary ticker launchd follows the same durable-checkout rule. Run
`.lastgit/install-canary-ticker-launchd.sh install` after canary runner changes,
then `.lastgit/install-canary-ticker-launchd.sh status` to confirm the loaded
plist points at an existing ticker script and to inspect the recent ticker log.

## Workflow

```bash
export LASTGIT_SOCKET=$HOME/.lastdb/data/folddb.sock
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

## Install deploy watcher

From a checkout of LastGit `main`:

```bash
.lastgit/install-deploy-launchd.sh install
.lastgit/install-deploy-launchd.sh status
```

## Install canary ticker

From a checkout of LastGit `main`:

```bash
.lastgit/install-canary-ticker-launchd.sh install
.lastgit/install-canary-ticker-launchd.sh status
```

## Pin

```bash
export LASTGIT_SOCKET=$HOME/.lastdb/data/folddb.sock
git config lastgit.socket "$LASTGIT_SOCKET"
```
