# Schema registration PoW — live dev proof

Status: **PASS** for the dev enforcement contract on 2026-07-21. The 24-hour dev soak is a separate downstream gate and must not start until this report's schema-infra change has passed required CI and its supervised deployment has completed.

## Deployed target

- Environment: `dev` (`us-west-2`)
- Schema Service Lambda: active; `SCHEMA_MUTATION_GATE_ENFORCE=true`
- Last runtime update observed: `2026-07-21T21:55:24Z`
- Corrected-client schema-infra merge: `ea485d0f31e485fe2a8fe1320b4428861a19f4e0`
- Required `ci-required`: success
- Required `deploy-pipeline`: success at `2026-07-21T22:34:16Z`
- Fold client with deterministic quota mode: `abf4a04f7a3e4ba876f32bf0f782d28be32baa96`
- Fold client with bounded negative-proof modes: `97ed83d71259b00afafc2350e8cb6f933af453`

- Fold submodule advanced by this proof change: `f4a93acac322c5350c8a4984034a641b4ba327ba` (includes the negative modes and the subsequent one-time schema-sync fix)

No endpoint, credential, key, signature, nonce, challenge token, HMAC material, or cloud account identifier is included in this report.

## Live behavior

The real production `SchemaServiceClient` was used against the deployed dev service.

| Contract | Live result |
|---|---|
| Missing proof | Initial novel registration was rejected before the client challenge flow (`node_key_required` / `proof_of_work_required` class). |
| Challenge → solve → signed retry | PASS with the deployed 18-bit challenge. |
| Novel registration | PASS; accepted after the signed PoW retry. |
| Idempotent repost | PASS with the same schema identity; no additional proof was required. |
| Invalid proof | HTTP 401 with exact reason `proof_of_work_invalid`. |
| Expired proof | HTTP 401 with exact reason `proof_of_work_expired`. |
| Shared hourly quota | Ten novel registrations were accepted for one ephemeral node identity; attempt 11 returned HTTP 429 with `quota_exceeded`. |
| Key handling | All probes used ephemeral signing keys; `private_key_persisted=false`. |

The acceptance probe reported 1,663 ms for the first registration and 1,863 ms for the identity-stable repost. Its redacted telemetry window contained 2 challenge events, 4 accepted events, and 2 initial rejection events. Shared quota-table items grew from 10 to 15 during the acceptance proof. The quota-exhaustion probe was run once only; it must not be repeated during soak.

The invalid and expired modes were each invoked exactly once. They construct otherwise signed requests but do not emit or retain request material. Both returned the expected stable rejection shape.

## Mutation-surface coverage

Enforcement is applied at the shared `POST /v1/schemas` mutation seam after idempotent classification. Required Fold CI covers these intent classifications and enforcement paths:

- a novel local owner claim is PoW-gated;
- a shared-discovery publication is DevCert-checked and PoW-gated;
- an unnamespaced/unowned create is classified as a new shared mutation and PoW-gated;
- an identity-stable repost is classified before the novel-mutation gate;
- quota errors preserve bucket, window, limit, and HTTP 429 semantics.

This central placement means callers cannot select a registration intent that bypasses the live gate while still creating a novel durable schema.

## Observability and alarms

At verification time:

- `schema-mutation-gate-hourly-quota-dev`: `OK`
- `schema-mutation-gate-internal-error-dev`: `OK`
- challenge, acceptance, initial-rejection, and quota-rejection signals were observed in CloudWatch logs by the secret-safe proof harness;
- the shared DynamoDB quota store changed during the successful novel-registration proof.

The CloudWatch dashboard and both alarms are provisioned by schema-infra. Production canary promotion checks the required mutation-gate alarms and fails closed if an alarm is `ALARM`, missing, or unreadable.

## Validation and delivery gates

- Fold PR #807: complete challenge headers; required Forge CI passed and merged.
- Fold PR #809: deterministic same-client quota probe; required Forge CI passed and merged.
- Fold PR #810: invalid/expired proof modes; required Forge CI passed and merged.
- Probe tests: 4 passed.
- `schema_service_client`: 30 unit tests plus 1 integration test passed.
- schema-infra canary alarm-gate tests: passed in required CI.

This report records the dev behavior as PASS. The next card may begin the 24-hour dev soak only after the schema-infra CR containing this report and Fold submodule advance has green required CI and a green supervised deployment.

## Rollback

Rollback is to set dev enforcement false through the normal schema-infra configuration and supervised deployment path, then verify the deployment and alarms. Do not edit the Lambda environment out of band, bypass CI/canary controls, or expose/rotate secret material as part of routine rollback.
