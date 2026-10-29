# Canonical vocabulary rollout

The schema service enforces precise field definitions through one code policy for every caller.
New concepts enter through normal schema publication and field declaration.
There is no special vocabulary signing key or vocabulary write endpoint.
App identity, permission, proof-of-work, and burst-rate checks remain active.
New schema and field registrations require an Exemem developer account and the registered app owner.
DEV has no hourly or daily new-schema count caps.
Production retains its existing count caps.

## Common field policy

Names identify the subject and property, with units and representation details when needed.
The code rejects vague names, app abbreviations, missing descriptions, and missing new-field types.
An existing name retains its definition and identity version.
Normalized string checks reject duplicate descriptions under different names.
Name tokens, description tokens, and vector embeddings identify possible semantic duplicates.
The code preserves distinct types, units, and roles.
A duplicate response identifies the existing concept for reuse.
Seeds, ordinary declarations, and snapshot imports use the same rules.

The app manifests in `sources.json` provide precise names, descriptions, types, and versions.
Apps submit those definitions through normal declarations.
They require no separate operator publication or secret lookup.
The read-only vocabulary command shows the resulting definitions.

## DEV phase

`phase` contains `dev` until real DEV operations pass.
Both release paths stop after the normal DEV checks.
The direct production deploy commands also refuse this phase.
No environment override opens production.

The `canonical-v2/` atomic definition generation does not fall back to legacy definitions.
The service starts with 113 seed concepts.
The four source app manifests contain 183 unique concepts, with one seed overlap.
The common policy determines admission and concept reuse during app declarations.
A source manifest is not an admission exception.

## Reset and recovery

The old definition generation stays available for recovery.
Its schemas, fields, declarations, near misses, releases, channels, and compatibility records do not enter the new prefix.
App identities, credentials, permissions, and quotas keep their common stores.
The new generation uses a separate retained embedding table.
The previous Lambda version retains its definition and embedding access during the canary.
The rollout does not change the primary home, archive, atom, file, or daemon.

Recovery definitions and exact legacy inventories stay outside Git.
No legacy name receives an exception because an old schema used it.
The previous DEV startup failure came from a retired schema-level mapping property in the old schema file.
The isolated prefix avoids that obsolete file.

## Production phase

Open `prod` through a separate reviewed source change after real DEV app operations pass.
Keep the existing production checks, 5% canary, alarms, and 24-hour period.
A code-canary rollback uses the retained canonical baseline and the same definition generation.
The reviewed atomic reset established canonical version 48 as that baseline.
Retired legacy version 47 is not the rollback target for the canonical code canary.
Legacy generation restoration requires a separate decision and data reconciliation after the atomic reset.
Keep recovery data during the canary.

### Readiness hold

The readiness change keeps `phase=dev`. Its merge cannot start a PROD deployment.
PROD currently uses the legacy definition generation; `canonical-v2/` is separate.
A random traffic split across those generations can lose read-after-write visibility.
The canary and promotion commands refuse different store identities or an incomplete identity check.
They compare the bucket, endpoint, storage region, definition namespace, and embedding store.
No environment flag skips this check.

The PROD CDK path requires the observed numbered `live` version and keeps it in place.
It publishes a candidate version as a separate stack output.
It refuses a new deployment while a weighted canary remains active.
The production deploy job and the canary ticker use one traffic-change concurrency group.
The canary checks the numbered candidate directly before it changes the public alias.
An absent previous version never causes an unguarded move to the candidate.

Before the separately approved PROD phase:

1. Refresh the recovery definitions and retain the previous Lambda version and embedding store.
2. Review the exact app source references in `sources.json` and the matching core revision.
3. Grant the reviewed deploy role permission for the qualified candidate reads through the IAM stack.
   The normal deploy workflow does not deploy that IAM stack.
4. Prepare the new generation through ordinary developer-account registration and common field validation.
   Keep PROD count limits and proof of work. Schedule registrations within those limits.
5. Review an explicit definition-generation cutover before public traffic can reach the new generation.
   A separate candidate check does not authorize this cutover or a local data conversion.
6. Complete isolated account, app, recovery, and qualified candidate checks.
7. Open the production phase through its reviewed source change and required release approval.

The ordinary 5% canary is permitted only when both numbered versions use the same definition store.
The alarm and 24-hour gates still control full promotion.

### Approved PROD definition retirement

Tom approved retirement of the old PROD schema definitions on 2026-10-28.
He selected a reviewed atomic reset before the code canary.
This reset activates the new definition generation in one step.
The 5% code canary does not cover that initial store transition.
The primary and its archive stay unchanged, except the separately approved ordinary LastSecrets credential and metadata entry.

The first source change provides candidate preparation only:

1. Use the accepted main CI and CodeQL results.
2. Deploy the reviewed IAM permission for qualified candidate reads.
3. Build the exact accepted core artifact in CI.
4. Publish a separate PROD candidate through CDK; preserve the observed public version without weights.
5. Match the actual numbered Lambda package and executable to the CI artifact.
6. Read qualified candidate health and vocabulary; keep public traffic on its previous version.

The manual `Prepare PROD candidate` workflow performs these steps from main.
`deploy.sh prod --candidate-only --skip-build` permits this separate candidate while `phase=dev` holds public traffic.
This mode requires CDK; it cannot select the public alias or start a canary.
The IAM-only CDK context constructs no service stack and needs no Lambda assets.

After candidate preparation, the next reviewed source change must identify the exact baseline version and code digest.
It must also identify the retained recovery definitions and the expected old public version.
Ordinary PROD developer-account and field declarations must pass before the atomic reset.
The reset must use the observed alias revision and refuse an active canary or unexpected generation.
Do not copy DEV definitions into PROD or rewrite a registry outside the common policy.
Keep the old definitions, previous Lambda version, and old embedding store for recovery.
The final release then uses the ordinary same-store 5% canary, alarms, and full 24-hour period.

### Atomic reset release

The intermediate `prod-reset` phase holds both ordinary PROD release paths.
It does not open the canary or permit an environment override.
The manual `Retire legacy PROD definitions` workflow requires accepted-main CI, CodeQL, and a successful current DEV deployment.
The pipeline emits the exact DEV smoke revision only after the actual smoke command succeeds.
The reset checks the corresponding explicit successful workflow step; an empty-diff deployment cannot supply that result.
It shares the normal deployment and PROD traffic concurrency controls.
Its IAM change adds only exact definition-object reads, two absent-key checks, and the two embedding-store status reads.

The reset controller fixes the reviewed legacy version 47, its code digest, and alias revision.
It fixes canonical baseline 48, its code digest, release, namespace, and embedding store.
It checks the retained immutable legacy S3 versions and the current legacy content against their reviewed hashes.
It requires the complete 295 approved concepts, the ordinary 183-field declaration, its owner, and both alarms OK.
Cold starts can rewrite identical seed images; content checks use canonical JSON hashes.

Only the accepted-main PROD role can execute the revision-checked alias change from 47 to 48.
The controller writes no definition object and deletes no old definition or embedding store.
All public traffic activates the canonical generation in this atomic step, without a random store split.
The alias description records the reset, without a code-canary clock.
The controller checks public health, vocabulary, and the existing declaration afterward.
An uncertain result never restores legacy traffic automatically after canonical writes can occur.
A rerun recognizes only the exact completed reset marker and performs completion reads.

After the real reset succeeds, a separate reviewed `prod` phase starts the ordinary same-store code canary.
That release retains canonical baseline 48 for rollback, the 5% weight, both alarms, and the full 24-hour period.
The later code canary does not cover the atomic reset itself.

Existing app configs retain their data identities.
A canonical name change does not move an existing record.
Existing-home conversion requires a separate operation.
