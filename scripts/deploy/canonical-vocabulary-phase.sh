#!/usr/bin/env bash
# A reviewed source change, not an environment override, opens the PROD phase.
canonical_vocabulary_phase() {
    local root phase
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    phase="$(cat "$root/canonical-vocabulary/phase")"
    case "$phase" in dev|prod-reset|prod) printf '%s\n' "$phase" ;;
        *) echo "FAIL: unknown canonical vocabulary rollout phase" >&2; return 1 ;;
    esac
}

canonical_vocabulary_require_environment() {
    local phase
    phase="$(canonical_vocabulary_phase)" || return
    if [ "$1" = prod ] && [ "$phase" != prod ]; then
        echo "FAIL: PROD traffic requires the reviewed prod phase; current phase is $phase" >&2
        return 1
    fi
}
