# Canonical vocabulary rollout

The schema service enforces precise field definitions through one code policy for every caller.
New concepts enter through normal schema publication and field declaration.
There is no special vocabulary signing key or vocabulary write endpoint.
App identity, permission, proof-of-work, and burst-rate checks remain active.
New schema and field registrations require an Exemem developer account and the registered app owner in PROD.
DEV accepts them without a developer account (`SCHEMA_OPEN_REGISTRATION`, Tom 2026-10-30).
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
The four source app manifests contain 182 unique concepts, with one seed overlap.
Brain's list dropped `native_file_reference` (type `Any`) at 6a3e3266; it held 183 before.
The common policy determines admission and concept reuse during app declarations.
A source manifest is not an admission exception.

## Reset and recovery

The old definition generation stays available for recovery.
Its schemas, fields, declarations, near misses, releases, channels, and compatibility records do not enter the new prefix.
App identities, credentials, permissions, and quotas keep their common stores.
The new generation uses a separate retained embedding table.
The previous Lambda version retains its definition and embedding access during the canary.
The rollout does not change the primary home, archive, record, file, or daemon.

Recovery definitions and exact legacy inventories stay outside Git.
No legacy name receives an exception because an old schema used it.
The previous DEV startup failure came from a retired schema-level mapping property in the old schema file.
The isolated prefix avoids that obsolete file.

## Production phase

The production phase is `prod`. Keep the existing production checks, 5% canary, alarms, and 24-hour period.
A code-canary rollback uses the retained previous live version and the same definition generation.
Legacy generation restoration requires a separate decision and data reconciliation.
Keep recovery data during the canary.

### Same-store canary

The canary and promotion commands refuse different store identities or an incomplete identity check.
They compare the bucket, endpoint, storage region, definition namespace, and embedding store.
No environment flag skips this check.

The PROD CDK path requires the observed numbered `live` version and keeps it in place.
It publishes a candidate version as a separate stack output.
It refuses a new deployment while a weighted canary remains active.
The production deploy job and the canary ticker use one traffic-change concurrency group.
The canary checks the numbered candidate directly before it changes the public alias.
An absent previous version never causes an unguarded move to the candidate.

The ordinary 5% canary applies only when both numbered versions use the same definition store.
The alarm and 24-hour gates still control full promotion.

Existing app configs retain their data identities.
A canonical name change does not move an existing record.
Existing-home conversion requires a separate operation.

### Catalog rebuild (2026-11-03)

Decision A9 of the advisory Schema Service design removes `Any`.
Tom chose to rebuild the stored catalog instead of converting it (`decision-2026-11-03-schema-service-any-stored-data-rebuild-from-feed`).
PROD `canonical-v2/definitions.json` was rewritten on 2026-11-03 at 19:06Z, with If-Match on the version it was built from:

- no schemas (54 before; 2 Brain schemas named `Any`);
- the 113 seed concepts and the 182 concepts of the ordinary publisher declaration, 294 in all (442 before);
- the ordinary declaration `approved-source-concepts-20261029` without `native_file_reference`, so 182 fields.

A declared field's identity covers only its declaration id, name, type, and version, so the other 182 fields keep their identities.
The prior object stays in S3 versioning (`ljNMqBxd6JwpRWVQ_PyYCy1CAlkaZls6`).
App schemas come back through the catalog feed, which reads the PROD registry lists into its own image.
The read routes do not serve the feed's records yet, so `GET /v1/schemas` lists no app schemas until they do.
