# LastGit home - schema-infra (GitHub = public mirror)

| Role | Location |
|------|----------|
| **SoT / CR / CI / merge** | `lastdb:///schema-infra` on the code node |
| **Public mirror** | `https://github.com/EdgeVector/schema-infra` (read-only for merge) |
| **Deploy gate** | LastGit `deploy-pipeline` on the forge host |

## Workflow

1. Agents open CRs with `lastgit cr` (venue = `lastgit`).
2. The code node runs `.lastgit/ci.sh` as `ci-required` and auto-merges green CRs.
3. The deploy watcher runs `.lastgit/deploy-pipeline.sh` after merged `main` updates.
4. The mirror job pushes LastGit `main` to GitHub `main` for public browse/clone only.

GitHub Actions are inert and disabled at the repository level. Do not merge or
deploy from GitHub.

## Pin

```bash
export LASTGIT_SOCKET=$HOME/.lastgit/code/data/folddb.sock
export LASTGIT_SCHEMA_MAP=$HOME/.lastgit/schema-map.json
```

The local checkout should also keep the structural pin:

```bash
git config lastgit.socket "$HOME/.lastgit/code/data/folddb.sock"
```
