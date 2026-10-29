#!/usr/bin/env python3
"""Activate the reviewed canonical generation atomically; never mix stores."""

import argparse
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[2]
REGION = "us-east-1"
ACCOUNT = "152335099025"
FUNCTION = "SchemaServiceStack-prod-SchemaServiceFnDF75D4BE-58KcDYig68xw"
BUCKET = "schema-service-prod-152335099025"
OLD = "47"
BASELINE = "48"
CORE = "c362298bfd4350b8600699a38fe5d5712baaf1ef"
OLD_CODE = "7vpn/iMywknsLWHotRpr4I/wrGmJk0NPr+XSRviWW5c="
BASELINE_CODE = "dXwjftu9GvYDffhmMGUHxRTHpz3nxfg+Os76shyWX2g="
BASELINE_RELEASE = "schema-infra@0596c5e43c8b"
OLD_REVISION = "60c8023c-ad78-41a8-b205-4e14f604ddf6"
VOCABULARY = "728c698123607158a12dbec0e644f136c010b0de03d75f4187c23a6e4a0c6858"
APP = "canonical-vocabulary-publisher"
OWNER = "746e7c25599d023235b27ace13edb16cd1b856ad09225415e82113e0552461f4"
DECLARATION = "fd_69de011d36374cac93d743494b089b8e"
DECLARATION_HASH = "2c9d933bb33bcf2efe6e30d923760931b6528ac8f1745faea5a0be6f39a03bcd"
# Immutable real recovery versions, not an instruction to rewrite the store.
RECOVERY = {
    "schemas.json": ("CoQx6ILs3a.deevvCO9eUoVXEXhg0sQK", 51,
                     "f54e7cc1788a48591a4a77e517c2215976147049bb116cf64bda53c4f04cd10b"),
    "canonical_fields.json": ("PRXaO2GxTYE33qI7JtFbp9J7XPkXrOO9", 310,
                              "ffa6b1fff760d4e6f0d6f62a8a0f49146b14b03ee3f87f0b32ed36a80231b3a3"),
}
ALARMS = ["schema-mutation-gate-hourly-quota-prod", "schema-mutation-gate-internal-error-prod"]
MARKER = "schema-definition-reset-v1:" + hashlib.sha256(
    f"{OLD}:{OLD_REVISION}:{BASELINE}:{BASELINE_CODE}:{VOCABULARY}:{DECLARATION_HASH}".encode()
).hexdigest()


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"),
                                     ensure_ascii=False).encode()).hexdigest()


def aws(*args):
    result = subprocess.run(["aws", *args, "--region", REGION, "--output", "json"],
                            capture_output=True, text=True, check=True, timeout=120)
    return json.loads(result.stdout)


def alias():
    result = aws("lambda", "get-alias", "--function-name", FUNCTION, "--name", "live")
    if result.get("RoutingConfig", {}).get("AdditionalVersionWeights"):
        raise ValueError("an active canary cannot cross a definition reset")
    return result


def configuration(version):
    query = ("{sha:CodeSha256,state:State,bucket:Environment.Variables.SCHEMA_STORE_BUCKET,"
             "namespace:Environment.Variables.SCHEMA_DEFINITION_NAMESPACE,"
             "endpoint:Environment.Variables.SCHEMA_STORE_ENDPOINT_URL,"
             "region:Environment.Variables.SCHEMA_STORE_REGION,"
             "embeddings:Environment.Variables.SCHEMA_EMBEDDINGS_TABLE,"
             "environment:Environment.Variables.ENVIRONMENT,"
             "release:Environment.Variables.OBS_SENTRY_RELEASE}")
    return aws("lambda", "get-function-configuration", "--function-name", FUNCTION,
               "--qualifier", version, "--query", query)


def verify_versions():
    for version, code, namespace, table in (
        (OLD, OLD_CODE, None, "schema-embeddings-prod"),
        (BASELINE, BASELINE_CODE, "canonical-v2", "schema-embeddings-prod-canonical-v2"),
    ):
        config = configuration(version)
        if (config["sha"] != code or config["state"] != "Active" or config["bucket"] != BUCKET
                or config.get("namespace") != namespace or config["embeddings"] != table
                or config["environment"] != "prod" or config.get("endpoint")
                or config.get("region") not in (None, "", REGION)):
            raise ValueError("the reviewed definition generation configuration changed")
        if version == BASELINE and config["release"] != BASELINE_RELEASE:
            raise ValueError("the canonical baseline release changed")
        if aws("dynamodb", "describe-table", "--table-name", table)["Table"]["TableStatus"] != "ACTIVE":
            raise ValueError("a retained embedding store is unavailable")


def object_json(key, directory, version=None):
    path = Path(directory) / "definition.json"
    args = ["s3api", "get-object", "--bucket", BUCKET, "--key", key]
    if version is not None:
        args += ["--version-id", version]
    aws(*args, str(path))
    return json.loads(path.read_text())


def verify_recovery(directory):
    for key, (version, count, expected) in RECOVERY.items():
        for selected in (version, None):
            data = object_json(key, directory, selected)
            if len(data["items"]) != count or digest(data) != expected:
                raise ValueError("the legacy definitions differ from the reviewed recovery snapshot")
    for key in ("declared_fields.json", "definitions.json"):
        result = aws("s3api", "list-objects-v2", "--bucket", BUCKET, "--prefix", key, "--max-keys", "2", "--no-paginate")
        if result.get("IsTruncated") or any(item["Key"] == key for item in result.get("Contents", [])):
            raise ValueError("an unexpected legacy definition object needs review")


def verify_alarms():
    values = aws("cloudwatch", "describe-alarms", "--alarm-names", *ALARMS)["MetricAlarms"]
    if {item["AlarmName"]: item["StateValue"] for item in values} != dict.fromkeys(ALARMS, "OK"):
        raise ValueError("both expected canary alarms must be OK")


def read_candidate(path, directory):
    spec = importlib.util.spec_from_file_location("schema_candidate", Path(__file__).with_name("check-schema-candidate.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.request(FUNCTION, REGION, BASELINE, path, directory)


def verify_candidate(directory):
    if read_candidate("/v1/health", directory).get("status") != "healthy":
        raise ValueError("the qualified baseline is unhealthy")
    vocabulary = read_candidate("/v1/fields/vocabulary", directory)
    if len(vocabulary["fields"]) != 295 or digest(vocabulary) != VOCABULARY:
        raise ValueError("the qualified vocabulary differs from the approved source set")
    if digest(read_candidate(f"/v1/fields/{DECLARATION}", directory)) != DECLARATION_HASH:
        raise ValueError("the ordinary publisher declaration differs")
    app = read_candidate(f"/v1/apps/{APP}", directory)
    public = base64.b64decode(app["owner_dev_pubkey"], validate=True)
    if app["app_id"] != APP or app["revoked"] is not False or len(public) != 32 or hashlib.sha256(public).hexdigest() != OWNER:
        raise ValueError("the ordinary publisher owner changed")
    return vocabulary


def verify_new_store(directory):
    data = object_json("canonical-v2/definitions.json", directory)
    if data["version"] != 1 or set(data["items"]) != {"registry"}:
        raise ValueError("the canonical atomic envelope changed")
    registry = data["items"]["registry"]
    if registry["schemas"] or set(registry["declared_fields"]) != {DECLARATION}:
        raise ValueError("unexpected canonical definitions need review")
    vocabulary = {"fields": registry["canonical_fields"], "name_policy_version": 1}
    if len(vocabulary["fields"]) != 295 or digest(vocabulary) != VOCABULARY or digest(registry["declared_fields"][DECLARATION]) != DECLARATION_HASH:
        raise ValueError("the durable canonical state differs from its qualified reads")


def verify_public(expected):
    stack = aws("cloudformation", "describe-stacks", "--stack-name", "SchemaServiceStack-prod")["Stacks"][0]
    outputs = {item["OutputKey"]: item["OutputValue"] for item in stack["Outputs"]}
    if outputs["SchemaServiceFunctionName"] != FUNCTION:
        raise ValueError("the production stack function changed")
    base = outputs["SchemaServiceApiUrl"].rstrip("/")
    if not base.startswith("https://") or not base.endswith(".execute-api.us-east-1.amazonaws.com"):
        raise ValueError("unexpected production API URL")
    for attempt in range(6):
        try:
            def get(path):
                with urlopen(base + path, timeout=30) as response:
                    return json.load(response)
            if get("/v1/health").get("status") != "healthy":
                raise ValueError("public health failed")
            vocabulary = get("/v1/fields/vocabulary")
            if vocabulary["name_policy_version"] != 1:
                raise ValueError("the public vocabulary policy differs")
            for name, definition in expected["fields"].items():
                actual = vocabulary["fields"][name]
                if any(actual[key] != definition[key] for key in ("description", "field_type", "version", "name_policy_version")):
                    raise ValueError("a reviewed public concept differs")
            if digest(get(f"/v1/fields/{DECLARATION}")) != DECLARATION_HASH:
                raise ValueError("the public declaration differs")
            return len(vocabulary["fields"])
        except (ValueError, KeyError, TypeError, OSError):
            if attempt == 5:
                raise
            time.sleep(2)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="Execute only from the accepted-main reset workflow")
    args = parser.parse_args()
    if (ROOT / "canonical-vocabulary/phase").read_text().strip() != "prod-reset":
        raise ValueError("the reviewed reset phase is required")
    core = subprocess.check_output(["git", "ls-tree", "HEAD", "fold"], cwd=ROOT, text=True).split()[2]
    if core != CORE:
        raise ValueError("the core revision differs from the qualified baseline")
    identity = aws("sts", "get-caller-identity")
    if identity["Account"] != ACCOUNT:
        raise ValueError("unexpected AWS account")
    if args.apply:
        head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
        if (os.environ.get("GITHUB_ACTIONS") != "true" or os.environ.get("GITHUB_REF") != "refs/heads/main"
                or os.environ.get("GITHUB_SHA") != head or not identity["Arn"].startswith(f"arn:aws:sts::{ACCOUNT}:assumed-role/SchemaInfraDeployProd/")):
            raise ValueError("the accepted-main deployment role is required")
    observed = alias()
    resume = observed["FunctionVersion"] == BASELINE and observed.get("Description") == MARKER
    if not resume and (observed["FunctionVersion"] != OLD or observed["RevisionId"] != OLD_REVISION):
        raise ValueError("the public version or reviewed revision changed")
    verify_versions()
    verify_alarms()
    with tempfile.TemporaryDirectory(prefix="schema-definition-reset-") as directory:
        vocabulary = verify_candidate(directory)
        verify_recovery(directory)
        if not resume:
            verify_new_store(directory)
        if not args.apply:
            print(json.dumps({"checks_pass": True, "public_version": observed["FunctionVersion"], "baseline": BASELINE,
                              "vocabulary_fields": 295, "ordinary_declared_fields": 183, "alias_change_attempted": False}))
            return
        if not resume:
            fresh = alias()
            if fresh["FunctionVersion"] != OLD or fresh["RevisionId"] != OLD_REVISION:
                raise ValueError("the alias changed during the preconditions")
            # One revision-checked pointer change, with no split across stores.
            # Never write, convert, import, or delete a definition object here.
            aws("lambda", "update-alias", "--function-name", FUNCTION, "--name", "live",
                "--function-version", BASELINE, "--routing-config", "{}", "--description", MARKER,
                "--revision-id", OLD_REVISION)
        after = alias()
        if after["FunctionVersion"] != BASELINE or after.get("Description") != MARKER:
            raise ValueError("the resulting alias needs recovery review")
        count = verify_public(vocabulary)
        final = alias()
        if final["FunctionVersion"] != BASELINE or final.get("Description") != MARKER:
            raise ValueError("the alias changed during the public checks")
    print(json.dumps({"atomic_reset_complete": True, "public_version": BASELINE, "namespace": "canonical-v2",
                      "public_vocabulary_fields": count, "legacy_recovery_retained": True, "canary_started": False}))


if __name__ == "__main__":
    os.environ["AWS_PAGER"] = ""
    os.environ["AWS_MAX_ATTEMPTS"] = "1"
    try:
        main()
    except ValueError as error:
        print(f"FAIL: {error}. Inspect the actual alias; do not restore legacy traffic automatically.", file=sys.stderr)
        sys.exit(1)
    except (KeyError, TypeError, IndexError, OSError, subprocess.SubprocessError):
        # An uncertain alias request can have committed. Do not retry it onto
        # legacy data after the new generation can accept writes. The same
        # reviewed marker permits a read-only completion on a rerun.
        print("FAIL: definition retirement did not complete. Inspect the actual alias; do not restore legacy traffic automatically.", file=sys.stderr)
        sys.exit(1)
