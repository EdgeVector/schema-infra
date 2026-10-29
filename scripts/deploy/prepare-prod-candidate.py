#!/usr/bin/env python3
"""Publish and verify a PROD candidate while the public alias stays unchanged."""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from urllib.request import urlopen
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[2]
REGION = "us-east-1"


def run(*args):
    return subprocess.run(args, cwd=ROOT, check=True, capture_output=True,
                          text=True, timeout=180).stdout.strip()


def aws(*args):
    return json.loads(run("aws", *args, "--region", REGION, "--output", "json"))


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def bootstrap_digest(path):
    with ZipFile(path) as archive:
        if archive.namelist() != ["bootstrap"]:
            raise ValueError("the artifact must contain only bootstrap")
        if not (archive.getinfo("bootstrap").external_attr >> 16) & 0o111:
            raise ValueError("bootstrap must be executable")
        with archive.open("bootstrap") as stream:
            return hashlib.file_digest(stream, "sha256").hexdigest()


def verify_inputs(manifest_path):
    manifest = json.loads(manifest_path.read_text())
    source = run("git", "rev-parse", "HEAD")
    core = run("git", "ls-tree", "HEAD", "fold").split()[2]
    if (manifest["schema_infra_oid"] != source or manifest["fold_oid"] != core
            or manifest["profile"] != "release"):
        raise ValueError("the artifact does not match this accepted source and release profile")
    inputs = f"fold={core}\n"
    for key, filename in (("recipe", "lambda-container-build.sh"),
                          ("driver", "remote-native-build.sh"),
                          ("lib", "lambda-container-build-lib.sh"),
                          ("builder", "ensure-builder-image.sh")):
        inputs += f"{key}={digest(ROOT / 'scripts' / filename)}\n"
    inputs += "profile=release\n"
    if hashlib.sha256(inputs.encode()).hexdigest() != manifest["input_digest"]:
        raise ValueError("the artifact input digest does not match the source")
    artifact = manifest_path.parent / "bootstrap.zip"
    zip_hash = digest(artifact)
    if (zip_hash != manifest["artifact_sha256_hex"] or
            base64.b64encode(bytes.fromhex(zip_hash)).decode() != manifest["artifact_code_sha256_b64"]):
        raise ValueError("the source artifact checksum does not match")
    extracted = ROOT / "fold/target/lambda/server_lambda-extracted/bootstrap"
    executable_hash = bootstrap_digest(artifact)
    if (digest(extracted) != executable_hash or
            digest(ROOT / "fold/target/lambda/server_lambda/bootstrap.zip") != zip_hash):
        raise ValueError("the CDK input does not match the verified artifact")
    return source, core, executable_hash


def outputs():
    stack = aws("cloudformation", "describe-stacks", "--stack-name", "SchemaServiceStack-prod")
    return {item["OutputKey"]: item["OutputValue"] for item in stack["Stacks"][0]["Outputs"]}


def public_target(function):
    alias = aws("lambda", "get-alias", "--function-name", function, "--name", "live")
    if alias.get("RoutingConfig", {}).get("AdditionalVersionWeights", {}):
        raise ValueError("an active canary must finish before candidate preparation")
    if not alias["FunctionVersion"].isdigit():
        raise ValueError("a numbered public version is required")
    return alias["FunctionVersion"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, type=Path)
    args = parser.parse_args()
    source, core, executable_hash = verify_inputs(args.manifest)
    function = outputs()["SchemaServiceFunctionName"]
    previous = public_target(function)
    subprocess.run([str(ROOT / "deploy.sh"), "prod", "--yes", "--skip-build", "--candidate-only"],
                   cwd=ROOT, check=True, timeout=3600)
    if public_target(function) != previous:
        raise ValueError("the public version changed; do not continue the rollout")
    candidate = outputs()["SchemaServiceCandidateVersion"]
    if not candidate.isdigit() or int(candidate) <= int(previous):
        raise ValueError("a separate newer numbered candidate is required")
    query = ("{sha:Configuration.CodeSha256,url:Code.Location,state:Configuration.State,"
             "namespace:Configuration.Environment.Variables.SCHEMA_DEFINITION_NAMESPACE,"
             "environment:Configuration.Environment.Variables.ENVIRONMENT,"
             "release:Configuration.Environment.Variables.OBS_SENTRY_RELEASE}")
    deployed = aws("lambda", "get-function", "--function-name", function,
                   "--qualifier", candidate, "--query", query)
    if (deployed["namespace"] != "canonical-v2" or deployed["environment"] != "prod"
            or deployed["state"] != "Active"):
        raise ValueError("the candidate configuration is not ready")
    # CDK repackages the executable. Check both its ZIP checksum and the exact
    # executable against the CI artifact; do not compare two different ZIPs.
    with tempfile.TemporaryDirectory(prefix="schema-prod-candidate-") as directory:
        path = Path(directory) / "candidate.zip"
        with urlopen(deployed["url"], timeout=180) as response, path.open("wb") as stream:
            while block := response.read(1024 * 1024):
                stream.write(block)
                if stream.tell() > 250 * 1024 * 1024:
                    raise ValueError("the candidate package exceeds the Lambda size limit")
        if (base64.b64encode(bytes.fromhex(digest(path))).decode() != deployed["sha"]
                or bootstrap_digest(path) != executable_hash):
            raise ValueError("the numbered Lambda package does not match the accepted source")
    subprocess.run([sys.executable, str(ROOT / "scripts/deploy/check-schema-candidate.py"),
                    "--function-name", function, "--region", REGION, "--version", candidate],
                   check=True, timeout=720)
    if public_target(function) != previous:
        raise ValueError("the public version changed during the qualified checks")
    print(json.dumps({"source": source, "core": core, "candidate": candidate,
                      "code_sha256": deployed["sha"], "release": deployed["release"],
                      "public_version_unchanged": previous, "namespace": deployed["namespace"]}))


if __name__ == "__main__":
    os.environ["AWS_PAGER"] = ""
    try:
        main()
    except (ValueError, KeyError, IndexError, TypeError, OSError, subprocess.SubprocessError):
        print("FAIL: PROD candidate preparation did not complete; inspect the CI stage before any traffic change.", file=sys.stderr)
        sys.exit(1)
