# Investigation: PR #471 500 Errors

## Summary
PR #471 caused all endpoints to return HTTP 500 after deployment to dev. The PR blamed Lambda architecture mismatch, but that premise is incorrect.

## Evidence

### Deploy Run #40538079736 Analysis

1. **Build completed successfully**: Lambda binary was built from scratch at fold commit 288a960b
   - Build time: 9m 47s
   - Artifact SHA256: b3aafac14832812136181b08d4a092dc9f405a5e7b26d1e439d66fb142904a8e
   - Size: 14655767 bytes
   - Cache: miss (fresh build, not reused)

2. **CloudFormation deployment succeeded**: Stack UPDATE_COMPLETE

3. **All smoke tests failed** with HTTP 500:
   ```
   FAIL /v1/health: HTTP 500 (want 200) body={"message":"Internal Server Error"}
   FAIL /health: HTTP 500 (want 200) body={"message":"Internal Server Error"}
   FAIL /v1/schemas: HTTP 500 (want 200) body={"message":"Internal Server Error"}
   FAIL /v2/apps HTTP 500 body={"message":"Internal Server Error"}
   ```

4. **No CloudWatch logs were checked** - PR #473 (revert) noted "Action needed after merge: Check CloudWatch logs" but this was never done.

### Architecture Mismatch Theory (Incorrect)

The PR #475 (current) blames architecture mismatch and adds:
```typescript
architecture: lambda.Architecture.X86_64,
```

However:
- **AWS Lambda default**: When architecture is omitted, Lambda defaults to `x86_64`
- **Layer compatibility**: The fastembed layer explicitly declares `compatibleArchitectures: [lambda.Architecture.X86_64]` (line 179)
- **Pre-#471 deployment**: Stack ran successfully without explicit architecture setting
- **Build process**: Binary was built with `--platform linux/amd64` (correct x86_64)

### Changes in PR #471

1. Added v2 API Gateway routes (11 new routes)
2. Added `APP_REGISTRY_VERIFIER_PUBKEY` env var (optional, shouldn't cause crash)
3. Bumped fold submodule: 4b1de188 → 288a960b (503 commits, including new ed25519-dalek dependency)

### Current State

The endpoint now returns 200 OK, suggesting the architecture fix resolved the issue - but WHY?

## Possible Root Causes

### Theory 1: CloudFormation/CDK Bug
CloudFormation might have failed to correctly infer x86_64 architecture from the layer when the function didn't specify it explicitly, despite AWS documentation saying it should default to x86_64.

### Theory 2: Lambda Runtime Update
An AWS Lambda runtime change between the last successful deploy (b9870bba) and PR #471 (74c79dc) could have changed default architecture inference behavior.

### Theory 3: Missing Dependency or Init Failure
The fold bump introduced new dependencies (ed25519-dalek) or init-time requirements that caused a startup panic, but this would show in CloudWatch logs.

### Theory 4: Fastembed Layer Incompatibility
The fastembed layer (ONNX Runtime native libraries) might not have been properly attached or compatible, but this should have failed before PR #471 too.

## Recommended Investigation

1. **Check CloudWatch logs** for `/aws/lambda/SchemaServiceStack-dev-SchemaServiceFnDF75D4BE-*` from 2026-10-27 16:22-16:23 UTC for actual Lambda init or runtime errors
2. **Reproduce locally**: Build bootstrap from fold at 288a960b and run with Lambda Runtime Interface Emulator WITHOUT explicit architecture to see if it fails
3. **Check AWS Service Health**: Look for any Lambda service issues or updates around Oct 27, 2026
4. **Test CDK behavior**: Create minimal test stack with layer but no function architecture to see if CDK/CloudFormation correctly infers it

## Conclusion

The architecture fix appears to work, but the root cause remains unclear. The explicit architecture setting may be a workaround for a CloudFormation inference bug rather than addressing the actual issue.
