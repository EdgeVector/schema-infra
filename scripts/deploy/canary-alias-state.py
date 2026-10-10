#!/usr/bin/env python3
"""Store and check a schema canary clock in the Lambda alias description."""
import argparse
import json
import math
import sys
from datetime import datetime, timedelta, timezone

MARKER = "\nschema-canary-v1:"


def positive(value):
    number = float(value)
    if not math.isfinite(number) or number <= 0:
        raise argparse.ArgumentTypeError("must be finite and positive")
    return number


def timestamp(value):
    if not isinstance(value, str):
        raise ValueError("canary timestamp must be text")
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("canary timestamp must include its UTC offset")
    return parsed.astimezone(timezone.utc)


def iso(value):
    return value.strftime("%Y-%m-%dT%H:%M:%SZ")


def parts(description):
    text, separator, proof = description.rpartition(MARKER)
    return (text, proof) if separator else (description, "")


def weighted_alias(alias, weight):
    weights = (alias.get("RoutingConfig") or {}).get("AdditionalVersionWeights") or {}
    if not isinstance(weights, dict):
        raise ValueError("invalid alias weight map")
    if not weights:
        return None
    if len(weights) != 1:
        raise ValueError("alias weight map must contain one canary")
    new, actual = next(iter(weights.items()))
    if not math.isfinite(float(actual)) or abs(float(actual) - weight) > 0.001:
        raise ValueError("alias canary weight differs from the configured weight")
    old = str(alias.get("FunctionVersion") or "")
    new = str(new)
    revision = str(alias.get("RevisionId") or "")
    if not old.isdigit() or not new.isdigit() or old == new or not revision:
        raise ValueError("weighted alias lacks a valid version pair or revision")
    return old, new, revision


def plan(args, alias):
    pair = weighted_alias(alias, args.weight)
    if pair is None:
        print("idle\t-\t-\t-\t-")
        return
    old, new, revision = pair
    _, raw = parts(str(alias.get("Description") or ""))
    try:
        proof = json.loads(raw)
        if (proof["old"] != old or proof["new"] != new
                or float(proof["weight"]) != args.weight):
            raise ValueError("canary proof does not match the alias")
        started = timestamp(proof["started"])
        now = datetime.now(timezone.utc)
        if started > now:
            raise ValueError("canary timestamp is in the future")
        promote = started + timedelta(hours=args.soak_hours)
    except (KeyError, TypeError, ValueError, OverflowError):
        # Keep the pair/revision: an ALARM can still roll it back safely.
        print("unproven\t%s\t%s\t%s\t-" % (old, new, revision))
        return
    action = "due" if now >= promote else "soaking"
    print("%s\t%s\t%s\t%s\t%s" % (action, old, new, revision, iso(promote)))


def stage(args, alias):
    revision = str(alias.get("RevisionId") or "")
    current = str(alias.get("FunctionVersion") or "")
    if not args.old.isdigit() or not args.new.isdigit() or args.old == args.new:
        raise ValueError("staging requires two distinct published versions")
    if not revision or alias.get("Name") != "live":
        raise ValueError("staging requires the live alias revision")
    if args.command == "adopt":
        pair = weighted_alias(alias, args.weight)
        if pair is None or pair[:2] != (args.old, args.new):
            raise ValueError("adoption version pair differs from the live weighted alias")
        started = timestamp(args.started_at)
        if started > datetime.now(timezone.utc):
            raise ValueError("adoption timestamp is in the future")
    else:
        if current not in (args.old, args.new):
            raise ValueError("live version changed before the canary pin")
        if (alias.get("RoutingConfig") or {}).get("AdditionalVersionWeights"):
            raise ValueError("another weighted canary is already active")
        started = datetime.now(timezone.utc)
    text, _ = parts(str(alias.get("Description") or ""))
    proof = {"old": args.old, "new": args.new, "weight": args.weight, "started": iso(started)}
    description = text + MARKER + json.dumps(proof, separators=(",", ":"))
    if len(description.encode("utf-8")) > 256:
        raise ValueError("canary proof and existing description exceed 256 bytes; preserve the text and stop")
    request = {"FunctionName": args.function_name, "Name": "live",
               "FunctionVersion": args.old, "RevisionId": revision,
               "RoutingConfig": {"AdditionalVersionWeights": {args.new: args.weight}},
               "Description": description}
    json.dump(request, sys.stdout)
    print()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    planner = commands.add_parser("plan")
    planner.add_argument("--weight", type=positive, default=0.05)
    planner.add_argument("--soak-hours", type=positive, default=24)
    for command in ("stage", "adopt"):
        mutation = commands.add_parser(command)
        mutation.add_argument("--function-name", required=True)
        mutation.add_argument("--old", required=True)
        mutation.add_argument("--new", required=True)
        mutation.add_argument("--weight", type=positive, default=0.05)
        if command == "adopt":
            mutation.add_argument("--started-at", required=True)
    args = parser.parse_args()
    try:
        if args.weight >= 1:
            raise ValueError("canary weight must be less than one")
        alias = json.load(sys.stdin)
        if not isinstance(alias, dict):
            raise ValueError("alias response must be an object")
        if args.command == "plan":
            plan(args, alias)
        else:
            stage(args, alias)
    except (KeyError, TypeError, ValueError, OverflowError) as error:
        print("canary alias: %s" % error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
