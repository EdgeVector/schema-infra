#!/usr/bin/env bash
#
# Lambda build steps that run INSIDE the amazonlinux:2023 container.
#
# Invoked by build.sh's `docker run` with this repo mounted at
# /build/schema-infra and the working directory set to
# /build/schema-infra/fold (the fold monorepo submodule).
#
# History: this used to live inline in build.sh as a single-quoted
# `bash -c '...'` string. That made apostrophes in comments fatal — an
# apostrophe in a comment (fold's) terminated the quoted string early,
# so the remainder executed in the OUTER shell and tripped `set -u` on
# $CARGO_HOME (the 2026-06-12 deploy outage, third quoting incident in
# this block). A real file has no such hazard and is shellcheck-able.
set -euo pipefail

# Defensively bind the env this script depends on. The docker run passes
# these via -e, but they were observed UNBOUND inside the container
# 2026-06-12 (set -u tripped on CARGO_HOME). An unbound CARGO_HOME makes
# `cargo install` drop the binary in the default ~/.cargo/bin instead of
# the .docker-cache/cargo/bin that PATH below covers, so every later
# invocation hits "command not found". Pin them to the same literals the
# docker -e flags use so the rest of the script is robust whether or not
# -e propagated.
export CARGO_HOME="${CARGO_HOME:-/build/schema-infra/.docker-cache/cargo}"
export RUSTUP_HOME="${RUSTUP_HOME:-/build/schema-infra/.docker-cache/rustup}"
export BUILD_PROFILE="${BUILD_PROFILE:-release}"

yum install -y gcc gcc-c++ cmake3 openssl-devel pkg-config tar gzip bzip2-libs perl git > /dev/null 2>&1

# Cargo needs to fetch private cross-repo git deps (e.g. exemem_common
# from EdgeVector/exemem-infra). Conditional on GH_PAT so local builds
# (no token) still work for fully-public-dep cases.
if [ -n "${GH_PAT:-}" ]; then
    git config --global url."https://x-access-token:${GH_PAT}@github.com/".insteadOf "https://github.com/"
fi

if [ ! -x /build/schema-infra/.docker-cache/cargo/bin/cargo ]; then
    curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable 2>&1 | tail -1
fi
export PATH="/build/schema-infra/.docker-cache/cargo/bin:$PATH"

# Install cargo-lambda from its PREBUILT release binary, NOT `cargo install`
# (compile from source). The from-source path was a tar pit on the cache-miss
# path and caused a multi-hour prod-deploy outage 2026-06-12:
#   - it recompiles cargo-lambda + deps on every cache miss (the GH Actions
#     cache stores .docker-cache/cargo/{registry,git}, never bin/), so the
#     tool is never actually cached;
#   - that fresh compile broke on the `time 0.3.48` yank (E0119 under stable
#     rustc);
#   - and even with that fixed, `cargo install` reported writing the binary to
#     .docker-cache/cargo/bin/cargo-lambda but that dir did not exist
#     afterward inside the same container — the runner bind mount did not
#     persist the write.
# The prebuilt musl build is a single static binary. Drop it on /usr/local/bin
# (always on PATH, not bind-mounted, no CARGO_HOME dependency), sha256-pinned
# so a tampered/rotated asset fails the build instead of shipping silently.
# Bump cl_ver + cl_sha together; the sha is published at <asset>.sha256.
if ! command -v cargo-lambda >/dev/null 2>&1; then
    cl_ver=1.9.1
    cl_sha=ff97518ea2b3c094fb385563f0784fef9191efcdc775101f4f80613820c050ec
    cl_url="https://github.com/cargo-lambda/cargo-lambda/releases/download/v${cl_ver}/cargo-lambda-v${cl_ver}.x86_64-unknown-linux-musl.tar.gz"
    curl -fsSL "$cl_url" -o /tmp/cargo-lambda.tar.gz
    echo "${cl_sha}  /tmp/cargo-lambda.tar.gz" | sha256sum -c -
    tar -xzf /tmp/cargo-lambda.tar.gz -C /usr/local/bin cargo-lambda
    chmod +x /usr/local/bin/cargo-lambda
fi

# --locked: build schema_service against fold's committed Cargo.lock instead
# of re-resolving. Without it the AL2023 build picks up whatever the registry
# serves that day — which broke the deploy 2026-06-12 when `time 0.3.48`
# shipped (E0119 conflicting From impls under stable rustc). fold pins
# `time 0.3.47`; honor it so resolution drift fails as a deliberate lockfile
# bump, not a silent prod-deploy outage. cargo-lambda forwards --locked
# through to the underlying `cargo build`.
#
# Invoke via the `cargo lambda` SUBCOMMAND form, not `cargo-lambda build`
# directly: cargo-lambda is a cargo subcommand whose clap expects argv[1]
# to be `lambda` (cargo supplies it). `cargo-lambda build` skips that and
# errors "unrecognized subcommand 'build'". `cargo lambda build` works now
# that the prebuilt binary is reliably on PATH (/usr/local/bin); the rustup
# cargo resolves it. Verified in an isolated AL2023 container.
cargo lambda build \
    --profile "$BUILD_PROFILE" \
    --output-format zip \
    --target x86_64-unknown-linux-gnu \
    --compiler cargo \
    --locked \
    -p schema_service_server_lambda
chmod -R a+rwX target/lambda/ 2>/dev/null || true
