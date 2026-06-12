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

if ! command -v cargo-lambda >/dev/null 2>&1; then
    # --locked compiles cargo-lambda against ITS OWN published Cargo.lock,
    # not a fresh registry resolve. This is the line that actually broke
    # the deploy 2026-06-12: on a cache miss the container recompiles
    # cargo-lambda from source, and an unlocked resolve pulled time 0.3.48
    # (E0119 under stable rustc), exit 101 BEFORE the schema_service build
    # (and its --locked) ever ran. The cargo-lambda release ships a
    # known-good lock; honor it, and pin the version so the tool stays
    # reproducible.
    # --root pins the install dir to CARGO_HOME so the absolute-path
    # invocation below is guaranteed to find it. Do NOT pipe to `tail -1`:
    # that ate cargo's "be sure to add ... to PATH" warning for days, which
    # is exactly why "command not found" was a mystery.
    cargo install cargo-lambda --version 1.9.1 --locked --root "$CARGO_HOME"
fi

# --locked: build against fold's committed Cargo.lock instead of
# re-resolving. Without it the AL2023 build picks up whatever the registry
# serves that day — which broke the deploy 2026-06-12 when `time 0.3.48`
# shipped (E0119 conflicting From impls under stable rustc). fold pins
# `time 0.3.47`; honor it. Resolution drift now fails as a deliberate
# lockfile bump, not a silent prod-deploy outage. (cargo-lambda forwards
# unknown flags through to cargo.)
# Invoke cargo-lambda by ABSOLUTE PATH under CARGO_HOME/bin (where --root
# above installs it). On the cache-miss path, neither the `cargo lambda`
# subcommand form ("no such command: lambda") nor the bare `cargo-lambda`
# form ("command not found") resolved 2026-06-12 — the install dir was not
# where PATH expected. Anchoring both install and invocation to
# $CARGO_HOME makes the lookup unconditional. The ls is a breadcrumb if
# the install layout ever shifts again.
ls -la "$CARGO_HOME/bin" || true
"$CARGO_HOME/bin/cargo-lambda" build \
    --profile "$BUILD_PROFILE" \
    --output-format zip \
    --target x86_64-unknown-linux-gnu \
    --compiler cargo \
    --locked \
    -p schema_service_server_lambda
chmod -R a+rwX target/lambda/ 2>/dev/null || true
