#!/usr/bin/env python3
"""Run one command with bounded, secret-safe progress reporting."""

from __future__ import annotations

import argparse
import os
import signal
import subprocess
import sys
import time


def positive_int(value: str) -> int:
    parsed = int(value)
    if parsed < 1:
        raise argparse.ArgumentTypeError("must be at least 1")
    return parsed


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--phase", required=True)
    parser.add_argument("--timeout-seconds", required=True, type=positive_int)
    parser.add_argument("--progress-seconds", type=positive_int, default=30)
    parser.add_argument("--stdout-file", required=True)
    parser.add_argument("--stderr-file", required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        parser.error("a command is required after --")

    started = time.monotonic()
    deadline = started + args.timeout_seconds
    next_progress = started + args.progress_seconds
    print(
        f"phase={args.phase} started timeout_seconds={args.timeout_seconds}",
        file=sys.stderr,
        flush=True,
    )

    with open(args.stdout_file, "wb") as stdout_file, open(
        args.stderr_file, "wb"
    ) as stderr_file:
        process = subprocess.Popen(
            command,
            stdout=stdout_file,
            stderr=stderr_file,
            start_new_session=True,
        )
        while True:
            return_code = process.poll()
            now = time.monotonic()
            if return_code is not None:
                elapsed = int(now - started)
                if return_code == 0:
                    print(
                        f"phase={args.phase} complete elapsed_seconds={elapsed}",
                        file=sys.stderr,
                        flush=True,
                    )
                else:
                    print(
                        f"FAIL: phase={args.phase} exited status={return_code} "
                        f"elapsed_seconds={elapsed}; captured diagnostics withheld",
                        file=sys.stderr,
                        flush=True,
                    )
                return return_code
            if now >= deadline:
                elapsed = int(now - started)
                print(
                    f"FAIL: phase={args.phase} exceeded timeout_seconds="
                    f"{args.timeout_seconds}; captured diagnostics withheld",
                    file=sys.stderr,
                    flush=True,
                )
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                    process.wait(timeout=5)
                except (ProcessLookupError, subprocess.TimeoutExpired):
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    process.wait()
                return 124
            if now >= next_progress:
                elapsed = int(now - started)
                print(
                    f"phase={args.phase} running elapsed_seconds={elapsed}",
                    file=sys.stderr,
                    flush=True,
                )
                next_progress = now + args.progress_seconds
            time.sleep(min(1.0, max(0.05, deadline - now)))


if __name__ == "__main__":
    raise SystemExit(main())
