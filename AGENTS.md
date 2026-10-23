<!-- last-stack:generated-evidence:start (managed by last-stack setup; edits inside are overwritten) -->
## Keep raw output outside Git (Tom, 2026-10-23)

- Do not commit raw logs, samples, request/reply dumps, generated receipts, or compressed copies.
- Use the CI summary and artifacts as the validation record. Link the run in the PR.
- Do not create a separate report or `artifact.json` for routine CI. This rule replaces older proof-file requirements.
- Keep useful source scripts and durable design conclusions in Git. Optional evidence files have a cap of 10 files and 100,000 bytes per PR.
- CI keeps raw output in the runner's temporary directory. Other output uses a unique directory outside Git. Use `LAST_STACK_EVIDENCE_ROOT`, or `${XDG_STATE_HOME:-$HOME/.local/state}/last-stack/artifacts/<repo>/`.
- CI records the source revision, download URL, checksum, and expiration. Archive selected results when long retention is necessary.
- Keep secrets out of all output. Verify retained output before cleanup.
- Keep the required `generated-evidence` check and output ignores. Do not evade the check. Product-data exceptions require an exact path and reason in the accepted base policy.

Policy: https://github.com/EdgeVector/.github/tree/main/generated-evidence.
<!-- last-stack:generated-evidence:end -->

# schema-infra repository instructions

## No tests or test coverage requirements (Tom, 2026-10-09)

Situation: `no-tests-all-repos-20261009`.

- Do not write, restore, or run tests in this repository.
- Remove test files, test commands, and test coverage requirements when you find them.
- Remove test requirements from linters and CI.
- Keep product build, format, lint, syntax, and deploy checks.
- This rule supersedes prior test, fixture, and mutation-probe requirements.
