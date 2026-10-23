#!/usr/bin/env python3
"""Retain wall-clock timings for the sequential class-A test suites."""

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import time


REPORT = Path("artifacts/test-timings/report.json")


def utc_now():
    return datetime.now(timezone.utc).isoformat()


def summary(report):
    suites = report["suites"]
    completed = [suite for suite in suites if suite["duration_seconds"] is not None]
    total = sum(suite["duration_seconds"] for suite in completed)
    lines = [
        "## Class-A test suite durations",
        "",
        f"Commit: `{report['commit']}`",
        f"Completed suites: {len(completed)}; combined wall time: {total:.3f} s.",
        "",
        "Suite wall time includes runner startup and any compilation; "
        "separate build-only steps are excluded.",
        "Class-B VM gates are not measured here.",
        "",
    ]
    if not report["complete"]:
        lines += [
            "**Partial run:** only suites reached before failure/cancellation "
            "are shown; an unfinished suite has no duration.",
            "",
        ]
    lines += [
        "| Suite (slowest first) | Seconds | Result |",
        "| --- | ---: | --- |",
    ]
    for suite in sorted(suites, key=lambda row: row["duration_seconds"] or 0, reverse=True):
        duration = suite["duration_seconds"]
        seconds = "—" if duration is None else f"{duration:.3f}"
        code = suite["exit_code"]
        result = "unfinished" if code is None else ("passed" if code == 0 else f"failed ({code})")
        lines.append(f"| {suite['name']} | {seconds} | {result} |")
    lines += [
        "",
        "Compare matching suite names and runner platforms across CI runs using "
        "the retained `test-timings-macos-*` artifacts (`report.json`).",
        "",
    ]
    return "\n".join(lines)


def save(report):
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    temporary = REPORT.with_suffix(".tmp")
    temporary.write_text(json.dumps(report, indent=2) + "\n")
    temporary.replace(REPORT)
    REPORT.with_name("summary.md").write_text(summary(report))


def initialize():
    commit = os.environ.get("GITHUB_SHA")
    if not commit:
        commit = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], text=True
        ).strip()
    save({
        "schema_version": 1,
        "started_at": utc_now(),
        "commit": commit,
        "ref": os.environ.get("GITHUB_REF", ""),
        "run_id": os.environ.get("GITHUB_RUN_ID", ""),
        "run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT", ""),
        "runner_os": platform.system(),
        "runner_release": platform.release(),
        "runner_arch": platform.machine(),
        "complete": False,
        "suites": [],
    })


def run_suite(report, name, command):
    if report["complete"]:
        raise ValueError("report is complete; run init before starting another run")
    if any(suite["name"] == name for suite in report["suites"]):
        raise ValueError(f"duplicate suite: {name}")
    suite = {
        "name": name,
        "command": command,
        "started_at": utc_now(),
        "duration_seconds": None,
        "exit_code": None,
    }
    report["suites"].append(suite)
    # Persist before launch so cancellation cannot masquerade as a completed suite.
    save(report)
    start = time.perf_counter()
    try:
        code = subprocess.run(command, check=False).returncode
    except FileNotFoundError as error:
        print(f"test-timing: {error}", file=sys.stderr)
        code = 127
    except OSError as error:
        print(f"test-timing: {error}", file=sys.stderr)
        code = 126
    except KeyboardInterrupt:
        code = 130
    suite["duration_seconds"] = time.perf_counter() - start
    suite["exit_code"] = code
    save(report)
    return code if code >= 0 else 128 - code


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_subparsers(dest="action", required=True)
    actions.add_parser("init", help="start a fresh report for verify-portable")
    run = actions.add_parser("run", help="time a suite without changing its output or exit status")
    run.add_argument("name")
    run.add_argument("command", nargs=argparse.REMAINDER)
    actions.add_parser("finish", help="mark a successful portable run complete")
    actions.add_parser("summary", help="print the report as Markdown, including partial runs")
    args = parser.parse_args()
    if args.action == "init":
        initialize()
        return 0
    if args.action == "run":
        if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", args.name):
            parser.error("suite name must contain lowercase words/numbers separated by hyphens")
        if args.command[:1] == ["--"]:
            args.command = args.command[1:]
        if not args.command:
            parser.error("a test command is required")
    report = json.loads(REPORT.read_text())
    if args.action == "run":
        return run_suite(report, args.name, args.command)
    if args.action == "finish":
        if not report["suites"] or any(suite["exit_code"] != 0 for suite in report["suites"]):
            raise ValueError("cannot finish a report with no suites or failed/unfinished suites")
        report["complete"] = True
        save(report)
    print(summary(report), end="")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError) as error:
        print(f"test-timing: {error}", file=sys.stderr)
        sys.exit(1)
