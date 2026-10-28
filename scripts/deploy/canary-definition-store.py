#!/usr/bin/env python3
"""Refuse traffic across distinct durable definition generations. Read-only."""

import argparse
import json
import re
import subprocess
import sys

QUERY = "{bucket:Environment.Variables.SCHEMA_STORE_BUCKET,endpoint:Environment.Variables.SCHEMA_STORE_ENDPOINT_URL,region:Environment.Variables.SCHEMA_STORE_REGION,namespace:Environment.Variables.SCHEMA_DEFINITION_NAMESPACE,embeddings:Environment.Variables.SCHEMA_EMBEDDINGS_TABLE}"


def definition_store(function, region, version):
    if not re.fullmatch(r"[1-9][0-9]*", version):
        raise ValueError("a numbered Lambda version is required")
    result = subprocess.run(
        ["aws", "lambda", "get-function-configuration", "--region", region,
         "--function-name", function, "--qualifier", version,
         "--query", QUERY, "--output", "json"],
        check=True, capture_output=True, text=True, timeout=45,
    )
    config = json.loads(result.stdout)
    if not isinstance(config, dict) or not config.get("bucket") or not config.get("embeddings"):
        raise ValueError("definition store identity is incomplete")
    return {key: value or "" for key, value in config.items()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--function-name", required=True)
    parser.add_argument("--region", required=True)
    parser.add_argument("--old", required=True)
    parser.add_argument("--new", required=True)
    args = parser.parse_args()
    old = definition_store(args.function_name, args.region, args.old)
    new = definition_store(args.function_name, args.region, args.new)
    changed = sorted(key for key in old if old[key] != new[key])
    if changed:
        print("REFUSED: definition stores differ (" + ", ".join(changed) +
              "). Candidate stays unrouted; a separate definition cutover is required.", file=sys.stderr)
        return 1
    if not new["namespace"]:
        # Equal legacy environment settings do not prove storage-format
        # compatibility when a code-only release changes the registry writer.
        raise ValueError("a versioned definition generation is required")
    print("Definition store identity matches for the numbered versions.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, subprocess.SubprocessError, OSError):
        print("REFUSED: cannot verify definition store identity; traffic stays held.", file=sys.stderr)
        sys.exit(1)
