#!/usr/bin/env python3
"""Read health and vocabulary from a numbered candidate, without public routing."""

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile


def request(function, region, version, path, directory):
    event = {
        "version": "2.0", "routeKey": f"GET {path}", "rawPath": path,
        "rawQueryString": "", "headers": {"host": "schema-candidate.invalid"},
        "requestContext": {"http": {"method": "GET", "path": path,
                                      "protocol": "HTTP/1.1", "sourceIp": "127.0.0.1",
                                      "userAgent": "schema-candidate-readiness"}},
        "isBase64Encoded": False,
    }
    output = Path(directory) / "response.json"
    result = subprocess.run(
        ["aws", "lambda", "invoke", "--region", region, "--function-name", function,
         "--qualifier", version, "--cli-binary-format", "raw-in-base64-out",
         "--payload", json.dumps(event), "--output", "json", str(output)],
        check=True, capture_output=True, text=True, timeout=330,
    )
    if json.loads(result.stdout).get("FunctionError"):
        raise ValueError("candidate invocation failed")
    response = json.loads(output.read_text())
    if response.get("statusCode") != 200 or response.get("isBase64Encoded", False):
        raise ValueError("candidate read failed")
    return json.loads(response["body"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--function-name", required=True)
    parser.add_argument("--region", required=True)
    parser.add_argument("--version", required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"[1-9][0-9]*", args.version):
        raise ValueError("a numbered candidate is required")
    with tempfile.TemporaryDirectory(prefix="schema-candidate-") as directory:
        health = request(args.function_name, args.region, args.version, "/v1/health", directory)
        if health.get("status") != "healthy":
            raise ValueError("candidate is not healthy")
        vocabulary = request(args.function_name, args.region, args.version,
                             "/v1/fields/vocabulary", directory)
        if not vocabulary.get("fields") or vocabulary.get("name_policy_version") != 1:
            raise ValueError("candidate vocabulary is unavailable")
    print("Numbered candidate health and canonical vocabulary reads pass; no alias changed.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, TypeError, subprocess.SubprocessError, OSError):
        print("FAIL: candidate health or vocabulary read failed; traffic stays held.", file=sys.stderr)
        sys.exit(1)
