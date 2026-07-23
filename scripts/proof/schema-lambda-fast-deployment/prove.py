#!/usr/bin/env python3
"""Terminal proof generator for north-star-schema-lambda-fast-deployment.

Fail-closed: every North Star completion criterion must be represented by
durable redacted evidence. First line of the report is PASS only when all
criteria hold. Never invents live PASS without evidence. No secret values
belong in evidence or the report.
"""
from __future__ import annotations

import argparse
import json
import math
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1
REQUIRED_FILES = (
    "meta.json",
    "releases.json",
    "digests.json",
    "dependency_budget.json",
    "path_classification.json",
    "coalescing.json",
    "safety_controls.json",
    "rollback.json",
)

# North Star SLO thresholds (seconds / counts).
P95_ARTIFACT_TO_DEV_LIVE_SEC = 5 * 60
P95_ARTIFACT_TO_PROD_CANARY_SEC = 10 * 60
P95_WARM_MERGE_TO_DEV_LIVE_SEC = 15 * 60
MAX_NORMAL_PACKAGES = 400
MAX_BOOTSTRAP_ZIP_BYTES = 15 * 1024 * 1024
MAX_ROLLBACK_SEC = 2 * 60
REQUIRED_RELEASE_COUNT = 10

BANNED_PACKAGE_NEEDLES = (
    "actix-web",
    "actix-http",
    "actix-codec",
    "actix-server",
    "actix-rt",
    "actix-service",
    "actix-utils",
    "actix-router",
    "actix-macros",
    "actix-web-codegen",
    "actix-tls",
    "actix-ws",
    "compress-io",
    "image",
    "jpeg-decoder",
    "png",
    "gif",
    "tiff",
    "sled",
    "reqwest",  # host-only model download clients
)

# Fail closed on anything that looks like a secret value in evidence text.
SECRET_PATTERNS = (
    re.compile(r"AKIA[0-9A-Z]{16}"),
    re.compile(r"(?i)aws_secret_access_key\s*[:=]\s*\S+"),
    re.compile(r"(?i)secret[_-]?access[_-]?key\s*[:=]\s*\S+"),
    re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    re.compile(r"(?i)bearer\s+[A-Za-z0-9\-._~+/]+=*"),
    re.compile(r"(?i)(api[_-]?key|password|client_secret|private_key)\s*[:=]\s*['\"]?[^'\"\s]{12,}"),
    re.compile(r"lastsecrets://[^\s\"']+\s*[:=]\s*[A-Za-z0-9+/=]{20,}"),
    re.compile(r"(?i)dsn\s*[:=]\s*https?://[^@\s]+:[^@\s]+@"),
)


def die(msg: str, code: int = 1) -> None:
    print(f"FAIL: {msg}", file=sys.stderr)
    raise SystemExit(code)


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        die(f"missing evidence file: {path.name}")
    except json.JSONDecodeError as exc:
        die(f"invalid JSON in {path.name}: {exc}")


def percentile_nearest_rank(values: list[float], p: float) -> float:
    if not values:
        die("cannot compute percentile of empty sample")
    ordered = sorted(values)
    if len(ordered) == 1:
        return float(ordered[0])
    # Nearest-rank method (common for small ops samples).
    rank = max(1, int(math.ceil(p / 100.0 * len(ordered))))
    return float(ordered[rank - 1])


def scan_secrets(root: Path) -> list[str]:
    hits: list[str] = []
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        if path.suffix.lower() not in {".json", ".md", ".txt", ".jsonl", ".yml", ".yaml"}:
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError as exc:
            hits.append(f"{path.name}: unreadable ({exc})")
            continue
        for pattern in SECRET_PATTERNS:
            if pattern.search(text):
                hits.append(f"{path.name}: matches secret pattern {pattern.pattern[:40]}…")
                break
    return hits


def require_keys(obj: dict[str, Any], keys: tuple[str, ...], label: str) -> None:
    missing = [k for k in keys if k not in obj]
    if missing:
        die(f"{label} missing keys: {', '.join(missing)}")


def parse_iso(ts: str) -> datetime:
    try:
        if ts.endswith("Z"):
            ts = ts[:-1] + "+00:00"
        return datetime.fromisoformat(ts)
    except ValueError:
        die(f"invalid timestamp: {ts}")


def check_meta(meta: dict[str, Any], now: datetime) -> list[str]:
    notes: list[str] = []
    require_keys(meta, ("schema_version", "collected_at", "source"), "meta.json")
    if meta["schema_version"] != SCHEMA_VERSION:
        die(f"unsupported evidence schema_version {meta['schema_version']} (want {SCHEMA_VERSION})")
    collected = parse_iso(str(meta["collected_at"]))
    if collected.tzinfo is None:
        collected = collected.replace(tzinfo=timezone.utc)
    max_age_hours = float(meta.get("max_age_hours", 24 * 30))
    age_hours = (now - collected).total_seconds() / 3600.0
    if age_hours < 0:
        die("meta.collected_at is in the future")
    if age_hours > max_age_hours:
        die(
            f"evidence is stale: collected_at={meta['collected_at']} "
            f"age_hours={age_hours:.1f} max_age_hours={max_age_hours}"
        )
    source = str(meta["source"])
    if source not in {"fixture", "live", "operator"}:
        die(f"meta.source must be fixture|live|operator, got {source!r}")
    notes.append(f"source={source} collected_at={meta['collected_at']} age_hours={age_hours:.1f}")
    return notes


def check_releases(releases: Any) -> tuple[list[str], dict[str, float]]:
    if not isinstance(releases, list):
        die("releases.json must be a JSON array")
    if len(releases) != REQUIRED_RELEASE_COUNT:
        die(
            f"releases.json must contain exactly {REQUIRED_RELEASE_COUNT} "
            f"representative releases, got {len(releases)}"
        )

    notes: list[str] = []
    artifact_to_dev: list[float] = []
    artifact_to_prod: list[float] = []
    warm_merge_to_dev: list[float] = []
    cold_merge_to_dev: list[float] = []
    digests_seen: dict[str, int] = {}

    for i, rel in enumerate(releases):
        label = f"releases[{i}]"
        if not isinstance(rel, dict):
            die(f"{label} must be an object")
        require_keys(
            rel,
            (
                "id",
                "fold_oid_short",
                "kind",
                "cache",
                "artifact_digest_sha256",
                "manifest_digest_sha256",
                "dev_code_sha256",
                "prod_code_sha256",
                "timings_sec",
                "cdk_invoked",
                "rust_compiled",
                "builds_for_digest",
            ),
            label,
        )
        rid = str(rel["id"])
        kind = str(rel["kind"])
        cache = str(rel["cache"])
        if kind not in {"code-only", "infrastructure", "no-impact"}:
            die(f"{label}.kind invalid: {kind}")
        if cache not in {"warm", "cold"}:
            die(f"{label}.cache invalid: {cache}")

        art = str(rel["artifact_digest_sha256"]).lower()
        man = str(rel["manifest_digest_sha256"]).lower()
        if not re.fullmatch(r"[0-9a-f]{64}", art):
            die(f"{label}.artifact_digest_sha256 must be 64 hex chars")
        if not re.fullmatch(r"[0-9a-f]{64}", man):
            die(f"{label}.manifest_digest_sha256 must be 64 hex chars")

        dev = str(rel["dev_code_sha256"])
        prod = str(rel["prod_code_sha256"])
        if not dev or not prod:
            die(f"{label}: empty CodeSha256")
        if dev != prod:
            die(f"{label}: dev_code_sha256 != prod_code_sha256")
        # Manifest digest must be recorded and identity-linked. Operators map
        # Lambda CodeSha256 to the published artifact; require explicit equality
        # flag via digests.json plus non-empty matching pair here.
        if art != man:
            # artifact zip digest and manifest digest may differ (manifest is
            # metadata). Require both present; cross-check is in digests.json.
            pass

        builds = int(rel["builds_for_digest"])
        if builds != 1:
            die(f"{label}: builds_for_digest must be 1 (built once), got {builds}")
        digests_seen[art] = digests_seen.get(art, 0) + 1

        timings = rel["timings_sec"]
        if not isinstance(timings, dict):
            die(f"{label}.timings_sec must be an object")
        require_keys(
            timings,
            (
                "artifact_ready_to_dev_live",
                "artifact_ready_to_prod_canary",
                "merge_to_dev_live",
            ),
            f"{label}.timings_sec",
        )
        a2d = float(timings["artifact_ready_to_dev_live"])
        a2p = float(timings["artifact_ready_to_prod_canary"])
        m2d = float(timings["merge_to_dev_live"])
        for name, val in (
            ("artifact_ready_to_dev_live", a2d),
            ("artifact_ready_to_prod_canary", a2p),
            ("merge_to_dev_live", m2d),
        ):
            if val < 0:
                die(f"{label}.timings_sec.{name} must be non-negative")

        # Timing SLOs apply to the ten consecutive *code-only* representative
        # releases. Non-code-only rows are allowed for path proofs but excluded
        # from p95 samples.
        if kind == "code-only":
            artifact_to_dev.append(a2d)
            artifact_to_prod.append(a2p)
            if cache == "warm":
                warm_merge_to_dev.append(m2d)
            else:
                cold_merge_to_dev.append(m2d)

        if kind == "code-only" and rel["cdk_invoked"] is not False:
            die(f"{label}: code-only release must have cdk_invoked=false")
        if kind == "code-only" and rel["rust_compiled"] is not False:
            # Code-only path promotes a prebuilt artifact; no compile on deploy.
            die(f"{label}: code-only release must have rust_compiled=false")

        notes.append(
            f"{rid}: kind={kind} cache={cache} "
            f"a2d={a2d:.0f}s a2p={a2p:.0f}s m2d={m2d:.0f}s "
            f"code_sha={dev[:12]}…"
        )

    if len(artifact_to_dev) < REQUIRED_RELEASE_COUNT:
        die(
            f"need {REQUIRED_RELEASE_COUNT} code-only releases for timing SLOs, "
            f"got {len(artifact_to_dev)}"
        )

    p95_a2d = percentile_nearest_rank(artifact_to_dev, 95)
    p95_a2p = percentile_nearest_rank(artifact_to_prod, 95)
    if p95_a2d > P95_ARTIFACT_TO_DEV_LIVE_SEC:
        die(
            f"p95 artifact_ready_to_dev_live={p95_a2d:.0f}s exceeds "
            f"{P95_ARTIFACT_TO_DEV_LIVE_SEC}s"
        )
    if p95_a2p > P95_ARTIFACT_TO_PROD_CANARY_SEC:
        die(
            f"p95 artifact_ready_to_prod_canary={p95_a2p:.0f}s exceeds "
            f"{P95_ARTIFACT_TO_PROD_CANARY_SEC}s"
        )
    if not warm_merge_to_dev:
        die("no warm code-only releases present for warm merge-to-dev SLO")
    p95_warm = percentile_nearest_rank(warm_merge_to_dev, 95)
    if p95_warm > P95_WARM_MERGE_TO_DEV_LIVE_SEC:
        die(
            f"p95 warm merge_to_dev_live={p95_warm:.0f}s exceeds "
            f"{P95_WARM_MERGE_TO_DEV_LIVE_SEC}s"
        )

    cold_note = "none measured"
    p95_cold: float | None = None
    if cold_merge_to_dev:
        p95_cold = percentile_nearest_rank(cold_merge_to_dev, 95)
        cold_note = f"p95={p95_cold:.0f}s n={len(cold_merge_to_dev)} (measured separately; not mixed into warm SLO)"

    metrics = {
        "p95_artifact_ready_to_dev_live_sec": p95_a2d,
        "p95_artifact_ready_to_prod_canary_sec": p95_a2p,
        "p95_warm_merge_to_dev_live_sec": p95_warm,
        "code_only_count": float(len(artifact_to_dev)),
        "warm_count": float(len(warm_merge_to_dev)),
        "cold_count": float(len(cold_merge_to_dev)),
        "unique_artifact_digests": float(len(digests_seen)),
    }
    notes.insert(
        0,
        (
            f"p95 artifact→dev-live={p95_a2d:.0f}s (limit {P95_ARTIFACT_TO_DEV_LIVE_SEC}s); "
            f"p95 artifact→prod-canary={p95_a2p:.0f}s (limit {P95_ARTIFACT_TO_PROD_CANARY_SEC}s); "
            f"p95 warm merge→dev-live={p95_warm:.0f}s (limit {P95_WARM_MERGE_TO_DEV_LIVE_SEC}s); "
            f"cold: {cold_note}"
        ),
    )
    return notes, metrics


def check_digests(digests: dict[str, Any], releases: list[dict[str, Any]]) -> list[str]:
    require_keys(
        digests,
        (
            "dev_prod_code_sha256_equal",
            "code_sha256_matches_manifest_for_all_releases",
            "per_release",
        ),
        "digests.json",
    )
    if digests["dev_prod_code_sha256_equal"] is not True:
        die("digests.json: dev_prod_code_sha256_equal must be true")
    if digests["code_sha256_matches_manifest_for_all_releases"] is not True:
        die("digests.json: code_sha256_matches_manifest_for_all_releases must be true")
    per = digests["per_release"]
    if not isinstance(per, list) or len(per) != len(releases):
        die("digests.json.per_release must list every release")
    notes: list[str] = []
    by_id = {str(r["id"]): r for r in releases}
    for entry in per:
        if not isinstance(entry, dict):
            die("digests.json.per_release entries must be objects")
        require_keys(
            entry,
            ("id", "manifest_digest_sha256", "dev_code_sha256", "prod_code_sha256", "matches"),
            "digests.per_release[]",
        )
        rid = str(entry["id"])
        if rid not in by_id:
            die(f"digests.json unknown release id {rid}")
        rel = by_id[rid]
        if entry["matches"] is not True:
            die(f"digests.json: release {rid} matches=false")
        if str(entry["dev_code_sha256"]) != str(rel["dev_code_sha256"]):
            die(f"digests.json: {rid} dev_code_sha256 inconsistent with releases.json")
        if str(entry["prod_code_sha256"]) != str(rel["prod_code_sha256"]):
            die(f"digests.json: {rid} prod_code_sha256 inconsistent with releases.json")
        if str(entry["manifest_digest_sha256"]).lower() != str(rel["manifest_digest_sha256"]).lower():
            die(f"digests.json: {rid} manifest_digest_sha256 inconsistent with releases.json")
        if str(entry["dev_code_sha256"]) != str(entry["prod_code_sha256"]):
            die(f"digests.json: {rid} dev/prod CodeSha256 mismatch")
        notes.append(f"{rid}: manifest={str(entry['manifest_digest_sha256'])[:12]}… code matches")
    return notes


def check_dependency_budget(dep: dict[str, Any]) -> list[str]:
    require_keys(
        dep,
        (
            "normal_package_count",
            "bootstrap_zip_size_bytes",
            "banned_packages_present",
            "banned_packages_checked",
            "embeddings_source",
        ),
        "dependency_budget.json",
    )
    count = int(dep["normal_package_count"])
    size = int(dep["bootstrap_zip_size_bytes"])
    if count >= MAX_NORMAL_PACKAGES:
        die(f"normal_package_count={count} exceeds limit {MAX_NORMAL_PACKAGES - 1}")
    if size >= MAX_BOOTSTRAP_ZIP_BYTES:
        die(f"bootstrap_zip_size_bytes={size} exceeds limit {MAX_BOOTSTRAP_ZIP_BYTES}")
    present = dep["banned_packages_present"]
    checked = dep["banned_packages_checked"]
    if not isinstance(present, list) or present:
        die(f"banned_packages_present must be empty list, got {present!r}")
    if not isinstance(checked, list) or not checked:
        die("banned_packages_checked must be a non-empty list")
    checked_l = {str(x).lower() for x in checked}
    missing = [b for b in BANNED_PACKAGE_NEEDLES if b not in checked_l]
    if missing:
        die(f"banned_packages_checked missing required needles: {', '.join(missing)}")
    emb = str(dep["embeddings_source"])
    if emb != "pinned_opt_layer_network_denied":
        die(
            "embeddings_source must be 'pinned_opt_layer_network_denied' "
            f"(got {emb!r})"
        )
    return [
        f"normal_package_count={count} (<{MAX_NORMAL_PACKAGES})",
        f"bootstrap_zip_size_bytes={size} (<{MAX_BOOTSTRAP_ZIP_BYTES})",
        f"banned_packages_present=[] checked={len(checked)}",
        f"embeddings_source={emb}",
    ]


def check_path_classification(path: dict[str, Any]) -> list[str]:
    require_keys(path, ("code_only", "infrastructure", "no_impact"), "path_classification.json")
    notes: list[str] = []
    co = path["code_only"]
    require_keys(co, ("invoked_cdk", "compiled_rust", "example_id"), "path_classification.code_only")
    if co["invoked_cdk"] is not False or co["compiled_rust"] is not False:
        die("code_only path must not invoke CDK or compile Rust")
    notes.append(f"code_only: example={co['example_id']} no-cdk no-rust-compile")

    infra = path["infrastructure"]
    require_keys(infra, ("invoked_cdk", "compiled_rust", "example_id"), "path_classification.infrastructure")
    if infra["invoked_cdk"] is not True:
        die("infrastructure path must invoke CDK")
    if infra["compiled_rust"] is not False:
        die("infrastructure path must not compile Rust")
    notes.append(f"infrastructure: example={infra['example_id']} cdk-without-rust")

    ni = path["no_impact"]
    require_keys(ni, ("skipped_deploy", "reason", "example_id"), "path_classification.no_impact")
    if ni["skipped_deploy"] is not True:
        die("no_impact path must skip deployment")
    reason = str(ni["reason"]).strip()
    if not reason:
        die("no_impact.reason must be a non-empty successful skip reason")
    notes.append(f"no_impact: example={ni['example_id']} skipped reason={reason!r}")
    return notes


def check_coalescing(co: dict[str, Any]) -> list[str]:
    require_keys(
        co,
        (
            "burst_commit_count",
            "deployed_tips",
            "deployed_tip_is_newest",
            "prod_alias_mutation_interrupted",
            "obsolete_tips_consumed_lane",
        ),
        "coalescing.json",
    )
    if int(co["burst_commit_count"]) < 3:
        die("coalescing: burst_commit_count must be >= 3")
    if int(co["deployed_tips"]) != 1:
        die("coalescing: deployed_tips must be 1 (newest tip only)")
    if co["deployed_tip_is_newest"] is not True:
        die("coalescing: deployed_tip_is_newest must be true")
    if co["prod_alias_mutation_interrupted"] is not False:
        die("coalescing: prod alias mutation must not be interrupted")
    if co["obsolete_tips_consumed_lane"] is not False:
        die("coalescing: obsolete tips must not each consume the lane")
    return [
        f"burst={co['burst_commit_count']} deployed_tips=1 newest=true "
        f"prod_alias_uninterrupted=true"
    ]


def check_safety(safety: dict[str, Any]) -> list[str]:
    require_keys(
        safety,
        (
            "dev_smoke",
            "prod_smoke",
            "mutation_gate_alarms",
            "weighted_canary",
            "soak_promotion_recorded",
            "secret_handling",
        ),
        "safety_controls.json",
    )
    if str(safety["dev_smoke"]).upper() != "PASS":
        die("dev_smoke must be PASS")
    if str(safety["prod_smoke"]).upper() != "PASS":
        die("prod_smoke must be PASS")
    if str(safety["mutation_gate_alarms"]).upper() not in {"OK", "PASS"}:
        die("mutation_gate_alarms must be OK/PASS")
    if safety["weighted_canary"] is not True:
        die("weighted_canary must be true")
    if safety["soak_promotion_recorded"] is not True:
        die("soak_promotion_recorded must be true")
    if str(safety["secret_handling"]) != "locator_only":
        die("secret_handling must be locator_only")
    return [
        "dev_smoke=PASS",
        "prod_smoke=PASS",
        f"mutation_gate_alarms={safety['mutation_gate_alarms']}",
        "weighted_canary=true",
        "soak_promotion_recorded=true",
        "secret_handling=locator_only",
    ]


def check_rollback(rb: dict[str, Any]) -> list[str]:
    require_keys(
        rb,
        ("method", "rebuild_required", "duration_sec", "verified"),
        "rollback.json",
    )
    if str(rb["method"]) != "alias_change_to_previous_version":
        die("rollback.method must be alias_change_to_previous_version")
    if rb["rebuild_required"] is not False:
        die("rollback must not require rebuild")
    duration = float(rb["duration_sec"])
    if duration < 0 or duration >= MAX_ROLLBACK_SEC:
        die(f"rollback.duration_sec={duration} must be in [0, {MAX_ROLLBACK_SEC})")
    if rb["verified"] is not True:
        die("rollback.verified must be true")
    return [f"method=alias_change_to_previous_version duration_sec={duration:.0f} rebuild=false"]


def render_report(
    *,
    verdict: str,
    evidence_dir: Path,
    generated_at: str,
    meta_notes: list[str],
    release_notes: list[str],
    metrics: dict[str, float],
    digest_notes: list[str],
    dep_notes: list[str],
    path_notes: list[str],
    coalescing_notes: list[str],
    safety_notes: list[str],
    rollback_notes: list[str],
    failures: list[str],
) -> str:
    lines: list[str] = [verdict, ""]
    lines.append("# Schema Lambda fast deployment — terminal proof")
    lines.append("")
    lines.append(f"Generated: {generated_at}")
    lines.append(f"Evidence: `{evidence_dir}`")
    lines.append("")
    lines.append(
        "This report is secret-safe. It records digests, timings, package counts, "
        "and pass/fail status only. No endpoint credentials, private keys, AWS "
        "secret material, or raw LastSecrets values are included."
    )
    lines.append("")
    lines.append("## North Star criteria")
    lines.append("")
    lines.append("| # | Criterion | Evidence |")
    lines.append("|---|---|---|")
    lines.append("| 1 | Build once per digest + verified manifest | releases.builds_for_digest=1 + digests |")
    lines.append("| 2 | Dev/prod CodeSha256 match manifest | digests.json |")
    lines.append(
        f"| 3 | p95 artifact→dev <5m / →prod-canary <10m | "
        f"{metrics.get('p95_artifact_ready_to_dev_live_sec', float('nan')):.0f}s / "
        f"{metrics.get('p95_artifact_ready_to_prod_canary_sec', float('nan')):.0f}s |"
    )
    lines.append(
        f"| 4 | Warm merge→dev <15m p95; cold separate | "
        f"warm p95={metrics.get('p95_warm_merge_to_dev_live_sec', float('nan')):.0f}s "
        f"cold_n={int(metrics.get('cold_count', 0))} |"
    )
    lines.append("| 5 | code-only / infra / no-impact paths | path_classification.json |")
    lines.append("| 6 | Tip coalescing (3-commit burst) | coalescing.json |")
    lines.append("| 7 | Deps <400 packages; zip <15MB | dependency_budget.json |")
    lines.append("| 8 | Banned packages absent; pinned embeddings layer | dependency_budget.json |")
    lines.append("| 9 | Smoke / canary / alarms / secret handling | safety_controls.json |")
    lines.append("| 10 | Rollback alias <2m, no rebuild | rollback.json |")
    lines.append("| 11 | Committed terminal report (this file) | prove harness |")
    lines.append("")
    lines.append("## Timing (ten code-only releases)")
    lines.append("")
    for note in release_notes:
        lines.append(f"- {note}")
    lines.append("")
    lines.append("## Digests")
    lines.append("")
    for note in digest_notes:
        lines.append(f"- {note}")
    lines.append("")
    lines.append("## Dependency budget")
    lines.append("")
    for note in dep_notes:
        lines.append(f"- {note}")
    lines.append("")
    lines.append("## Path classification")
    lines.append("")
    for note in path_notes:
        lines.append(f"- {note}")
    lines.append("")
    lines.append("## Coalescing")
    lines.append("")
    for note in coalescing_notes:
        lines.append(f"- {note}")
    lines.append("")
    lines.append("## Safety controls")
    lines.append("")
    for note in safety_notes:
        lines.append(f"- {note}")
    lines.append("")
    lines.append("## Rollback")
    lines.append("")
    for note in rollback_notes:
        lines.append(f"- {note}")
    lines.append("")
    lines.append("## Evidence metadata")
    lines.append("")
    for note in meta_notes:
        lines.append(f"- {note}")
    lines.append("")
    if failures:
        lines.append("## Failures")
        lines.append("")
        for f in failures:
            lines.append(f"- {f}")
        lines.append("")
    lines.append("## Operator command")
    lines.append("")
    lines.append("```bash")
    lines.append("# Fail closed without evidence:")
    lines.append("scripts/proof/schema-lambda-fast-deployment/prove.sh")
    lines.append("")
    lines.append("# Against collected redacted evidence:")
    lines.append(
        "scripts/proof/schema-lambda-fast-deployment/prove.sh "
        "--evidence-dir path/to/evidence"
    )
    lines.append("")
    lines.append("# Fixture self-check (CI):")
    lines.append("tests/proof/schema-lambda-fast-deployment/test-prove.sh")
    lines.append("```")
    lines.append("")
    return "\n".join(lines)


def evaluate(evidence_dir: Path, now: datetime | None = None) -> tuple[str, str, int]:
    """Return (verdict, report_markdown, exit_code)."""
    now = now or datetime.now(timezone.utc)
    generated_at = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    failures: list[str] = []

    if not evidence_dir.is_dir():
        report = (
            f"FAIL\n\n# Schema Lambda fast deployment — terminal proof\n\n"
            f"Generated: {generated_at}\n\n"
            f"No evidence directory at `{evidence_dir}`.\n"
            "Harness fails closed. Collect redacted evidence or pass "
            "`--evidence-dir` to a complete fixture/live pack.\n"
        )
        return "FAIL", report, 1

    secret_hits = scan_secrets(evidence_dir)
    if secret_hits:
        msg = "secret-bearing evidence: " + "; ".join(secret_hits)
        failures.append(msg)
        report = (
            f"FAIL\n\n# Schema Lambda fast deployment — terminal proof\n\n"
            f"Generated: {generated_at}\n\n"
            f"Evidence rejected (secret scan):\n\n"
            + "\n".join(f"- {h}" for h in secret_hits)
            + "\n"
        )
        return "FAIL", report, 1

    missing = [name for name in REQUIRED_FILES if not (evidence_dir / name).is_file()]
    if missing:
        report = (
            f"FAIL\n\n# Schema Lambda fast deployment — terminal proof\n\n"
            f"Generated: {generated_at}\n\n"
            f"Incomplete evidence under `{evidence_dir}`.\n"
            f"Missing: {', '.join(missing)}\n"
        )
        return "FAIL", report, 1

    meta = load_json(evidence_dir / "meta.json")
    releases = load_json(evidence_dir / "releases.json")
    digests = load_json(evidence_dir / "digests.json")
    dep = load_json(evidence_dir / "dependency_budget.json")
    path = load_json(evidence_dir / "path_classification.json")
    coalescing = load_json(evidence_dir / "coalescing.json")
    safety = load_json(evidence_dir / "safety_controls.json")
    rollback = load_json(evidence_dir / "rollback.json")

    if not isinstance(meta, dict):
        die("meta.json must be an object")
    if not isinstance(digests, dict):
        die("digests.json must be an object")
    if not isinstance(dep, dict):
        die("dependency_budget.json must be an object")
    if not isinstance(path, dict):
        die("path_classification.json must be an object")
    if not isinstance(coalescing, dict):
        die("coalescing.json must be an object")
    if not isinstance(safety, dict):
        die("safety_controls.json must be an object")
    if not isinstance(rollback, dict):
        die("rollback.json must be an object")

    meta_notes = check_meta(meta, now)
    release_notes, metrics = check_releases(releases)
    digest_notes = check_digests(digests, releases)
    dep_notes = check_dependency_budget(dep)
    path_notes = check_path_classification(path)
    coalescing_notes = check_coalescing(coalescing)
    safety_notes = check_safety(safety)
    rollback_notes = check_rollback(rollback)

    report = render_report(
        verdict="PASS",
        evidence_dir=evidence_dir,
        generated_at=generated_at,
        meta_notes=meta_notes,
        release_notes=release_notes,
        metrics=metrics,
        digest_notes=digest_notes,
        dep_notes=dep_notes,
        path_notes=path_notes,
        coalescing_notes=coalescing_notes,
        safety_notes=safety_notes,
        rollback_notes=rollback_notes,
        failures=failures,
    )
    return "PASS", report, 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Generate proofs/schema-lambda-fast-deployment.md (PASS only when complete)."
    )
    parser.add_argument(
        "--evidence-dir",
        type=Path,
        default=None,
        help="Directory of redacted evidence JSON files. Default: $SCHEMA_LAMBDA_PROOF_EVIDENCE "
        "or <repo>/target/schema-lambda-fast-deployment-evidence (fails if missing).",
    )
    parser.add_argument(
        "--report",
        type=Path,
        default=None,
        help="Output report path (default: <repo>/proofs/schema-lambda-fast-deployment.md).",
    )
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=None,
        help="Repo root (default: inferred from this script).",
    )
    args = parser.parse_args(argv)

    script_dir = Path(__file__).resolve().parent
    repo_root = (args.repo_root or script_dir.parents[2]).resolve()
    evidence = args.evidence_dir
    if evidence is None:
        env = __import__("os").environ.get("SCHEMA_LAMBDA_PROOF_EVIDENCE")
        if env:
            evidence = Path(env)
        else:
            evidence = repo_root / "target" / "schema-lambda-fast-deployment-evidence"
    evidence = evidence.resolve() if evidence.exists() or evidence.is_absolute() else (repo_root / evidence).resolve()

    report_path = args.report or (repo_root / "proofs" / "schema-lambda-fast-deployment.md")
    report_path = report_path if report_path.is_absolute() else (repo_root / report_path)
    report_path.parent.mkdir(parents=True, exist_ok=True)

    from io import StringIO
    import contextlib

    stderr_buf = StringIO()
    verdict = "FAIL"
    report = ""
    code = 1
    try:
        with contextlib.redirect_stderr(stderr_buf):
            verdict, report, code = evaluate(evidence)
    except SystemExit as exc:
        code = int(exc.code) if isinstance(exc.code, int) else 1
        err = stderr_buf.getvalue().strip() or str(exc)
        generated_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        report = (
            f"FAIL\n\n# Schema Lambda fast deployment — terminal proof\n\n"
            f"Generated: {generated_at}\n\n"
            f"Evidence under `{evidence}` failed closed validation.\n\n"
            f"```\n{err or 'validation error'}\n```\n"
        )
        verdict = "FAIL"
        if err:
            print(err, file=sys.stderr)

    report_path.write_text(report, encoding="utf-8")
    print(f"PROOF_REPORT={report_path}")
    print(f"PROOF_VERDICT={verdict}")
    first = report.splitlines()[0] if report else ""
    if first != verdict:
        print(f"FAIL: report first line {first!r} != verdict {verdict!r}", file=sys.stderr)
        return 1
    return code


if __name__ == "__main__":
    raise SystemExit(main())
