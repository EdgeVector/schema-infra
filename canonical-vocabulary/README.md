# Canonical vocabulary rollout

The schema service enforces precise field definitions through one code policy for every caller.
New concepts enter through normal schema publication and field declaration.
There is no special vocabulary signing key or vocabulary write endpoint.
App identity, permission, mutation, and quota checks remain active.

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

The `canonical-v1/` definition generation does not fall back to legacy definitions.
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
A rollback uses the retained previous version and its previous definition generation.
Keep recovery data during the canary.

Existing app configs retain their data identities.
A canonical name change does not move an existing record.
Existing-home conversion requires a separate operation.
