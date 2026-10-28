# Canonical vocabulary rollout

The current service retains arbitrary app field names and obsolete schema formats.
The new service requires an explicitly approved standard vocabulary.
The rollout uses `canonical-v1/` for definition files and a separate embedding store.
App identities, credentials, and quotas keep their current stores.

## DEV phase

`phase` contains `dev` until real DEV operations pass.
Both release paths stop after the normal DEV checks.
The direct production deploy commands also refuse this phase.
No environment override opens production.

The definition prefix starts empty and does not read legacy definitions as a fallback.
The service seeds 113 reviewed concepts.
The four source manifests in `sources.json` add 183 app concepts.
One app concept also appears in the seed. The combined vocabulary contains 295 concepts.
The bundle command rejects conflicting definitions before operator publication.

`bin/canonical-vocabulary-bundle` accepts explicit reviewed source paths.
It writes the operator publication input outside Git.
It does not contact LastDB or the schema service.
Use the pinned sources and verify their checksums before publication.
The schema-service `canonical-vocabulary` command signs the batch through LastSecrets.
Use the dedicated publisher locator; app developer and compatibility keys cannot approve vocabulary.

## Reset scope

The old definition generation stays available for recovery.
Its schemas, canonical fields, declarations, near misses, releases, channels, and compatibility records do not enter the new prefix.
This removes obsolete names from the active generation without a physical delete of the old generation.
App identities and their permissions remain in the common app store.
The previous Lambda version retains its existing definition and embedding access during the canary.
No primary data, atom, file, or daemon changes as part of this rollout.

A definition-only recovery snapshot stays outside Git.
The exact legacy inventory and cloud operation output also stay outside Git.
The pre-activation review checks for unrelated definitions that already meet the approved contract.
An unknown name receives no automatic approval because it appeared in an old schema.

The previous DEV failure came from a retired schema-level mapping property in its stored schema file.
A direct health call to retained DEV version 64 returns the parse error during startup.
The isolated prefix avoids that obsolete file.
It also avoids a second copy of app identities.

## Production phase

Open `prod` through a separate reviewed source change after operator approval and real DEV operations.
The existing production checks, 5% canary, alarms, and 24-hour period remain required.
A canary rollback uses the retained previous version and its previous definition generation.
Do not delete recovery data during the canary.

The app PRs keep legacy configs on their current data identities.
A new canonical identity does not move an existing record.
Existing-home data conversion requires a separate operation.
