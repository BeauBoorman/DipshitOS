"""Regression tests for retained suite timings, using isolated subprocesses."""

import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "tools/test-timing.py"
SPEC = importlib.util.spec_from_file_location("test_timing", SCRIPT)
timing = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(timing)


class TestTestTiming(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.cwd = Path(self.directory.name)
        self.report_path = self.cwd / "artifacts/test-timings/report.json"
        self.env = {**os.environ, "GITHUB_SHA": "abc123", "GITHUB_RUN_ID": "42",
                    "GITHUB_RUN_ATTEMPT": "2"}
        self.cli("init")

    def cli(self, *args, expected=0):
        result = subprocess.run(
            [sys.executable, str(SCRIPT), *args], cwd=self.cwd,
            env=self.env, text=True, capture_output=True,
        )
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result

    def report(self):
        return json.loads(self.report_path.read_text())

    def test_success_retains_metadata_output_and_duration(self):
        result = self.cli("run", "python-example", "--", sys.executable, "-c",
                          "import sys; print('out'); print('err', file=sys.stderr)")
        self.assertEqual(result.stdout, "out\n")
        self.assertEqual(result.stderr, "err\n")
        report = self.report()
        self.assertEqual(report["schema_version"], 1)
        self.assertEqual(report["commit"], "abc123")
        self.assertEqual(report["run_id"], "42")
        self.assertEqual(report["run_attempt"], "2")
        self.assertTrue(report["runner_os"])
        self.assertTrue(report["runner_arch"])
        self.assertFalse(report["complete"])
        suite = report["suites"][0]
        self.assertEqual(suite["exit_code"], 0)
        self.assertGreater(suite["duration_seconds"], 0)
        self.assertEqual(suite["command"][:2], [sys.executable, "-c"])
        self.cli("finish")
        self.assertTrue(self.report()["complete"])
        self.assertNotIn("**Partial run:**", self.cli("summary").stdout)

    def test_failure_keeps_exit_status_and_partial_report(self):
        self.cli("run", "failing", "--", sys.executable, "-c",
                 "raise SystemExit(7)", expected=7)
        self.assertEqual(self.report()["suites"][0]["exit_code"], 7)
        summary = self.cli("summary").stdout
        self.assertIn("failed (7)", summary)
        self.assertIn("**Partial run:**", summary)
        self.assertEqual(summary, self.report_path.with_name("summary.md").read_text())
        self.cli("finish", expected=1)
        self.assertFalse(self.report()["complete"])

    def test_missing_executable_is_retained_as_failure(self):
        self.cli("run", "missing", "--", str(self.cwd / "missing"), expected=127)
        self.assertEqual(self.report()["suites"][0]["exit_code"], 127)

    def test_signal_failure_is_not_reported_as_success(self):
        self.cli("run", "signalled", "--", sys.executable, "-c",
                 "import os, signal; os.kill(os.getpid(), signal.SIGTERM)",
                 expected=128 + signal.SIGTERM)
        self.assertEqual(self.report()["suites"][0]["exit_code"], -signal.SIGTERM)

    def test_multiple_suites_and_slowest_first_summary(self):
        self.cli("run", "first", "--", sys.executable, "-c", "pass")
        self.cli("run", "second", "--", sys.executable, "-c", "pass")
        report = self.report()
        self.assertEqual([suite["name"] for suite in report["suites"]], ["first", "second"])
        report["suites"][0]["duration_seconds"] = 1.25
        report["suites"][1]["duration_seconds"] = 3.5
        summary = timing.summary(report)
        self.assertLess(summary.index("| second |"), summary.index("| first |"))
        self.assertIn("4.750 s", summary)

    def test_reset_does_not_reuse_previous_run_data(self):
        self.cli("run", "old-run", "--", sys.executable, "-c", "pass")
        self.cli("finish")
        self.cli("init")
        self.assertEqual(self.report()["suites"], [])
        self.assertFalse(self.report()["complete"])
        self.assertNotIn("old-run", self.cli("summary").stdout)

    def test_bad_invocations_cannot_run_a_command_or_finish_empty_report(self):
        self.cli("run", "empty", expected=2)
        self.cli("run", "bad|name", "--", sys.executable, "-c", "pass", expected=2)
        self.cli("finish", expected=1)
        self.assertEqual(self.report()["suites"], [])

    def test_duplicate_names_and_completed_reports_are_rejected(self):
        self.cli("run", "unique", "--", sys.executable, "-c", "pass")
        self.cli("run", "unique", "--", sys.executable, "-c", "pass", expected=1)
        self.cli("finish")
        self.cli("run", "late", "--", sys.executable, "-c", "pass", expected=1)
        self.assertEqual(len(self.report()["suites"]), 1)

    def test_unfinished_suite_survives_abrupt_interruption(self):
        report = self.report()
        with patch.object(timing, "REPORT", self.report_path), \
                patch.object(timing.subprocess, "run", side_effect=SystemExit(143)):
            with self.assertRaises(SystemExit):
                timing.run_suite(report, "interrupted", ["unused"])
        suite = self.report()["suites"][0]
        self.assertIsNone(suite["exit_code"])
        self.assertIsNone(suite["duration_seconds"])
        self.assertIn("| interrupted | — | unfinished |", self.cli("summary").stdout)
        self.cli("finish", expected=1)

    def test_elapsed_time_uses_monotonic_clock(self):
        report = self.report()
        with patch.object(timing, "REPORT", self.report_path), \
                patch.object(timing.time, "perf_counter", side_effect=[10.0, 12.5]), \
                patch.object(timing.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)):
            self.assertEqual(timing.run_suite(report, "monotonic", ["unused"]), 0)
        self.assertEqual(self.report()["suites"][0]["duration_seconds"], 2.5)


if __name__ == "__main__":
    unittest.main()
