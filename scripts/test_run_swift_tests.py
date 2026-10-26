from __future__ import annotations

from contextlib import redirect_stderr, redirect_stdout
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

import report_test_events as event_reporter
import run_swift_tests as runner


class RunSwiftTestsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.package = self.root / "package"
        self.package.mkdir()
        (self.package / "Package.swift").write_text("// fixture\n", encoding="utf-8")
        self.events = self.root / "reports" / "run.jsonl"

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def make_process(self, returncode: int | None = 0) -> Mock:
        process = Mock()
        process.pid = 12345
        process.returncode = returncode
        process.wait.return_value = returncode
        process.poll.return_value = returncode
        return process

    def write_synthetic_events(self, path: Path, duration: float) -> None:
        records = []
        for kind, instant in (("runStarted", 0), ("runEnded", duration)):
            records.append(
                {
                    "version": 0,
                    "kind": "event",
                    "payload": {
                        "kind": kind,
                        "instant": {"absolute": instant},
                        "messages": [],
                    },
                }
            )
        path.write_text(
            "".join(json.dumps(record) + "\n" for record in records),
            encoding="utf-8",
        )

    def run_with_mocks(
        self,
        *,
        test_returncode: int | None = 0,
        report_status: int = 0,
        skip_build: bool = False,
        filter_pattern: str | None = None,
    ) -> tuple[int, Mock, Mock, Mock]:
        process = self.make_process(test_returncode)
        build = Mock(return_value=subprocess.CompletedProcess([], 0))
        event_report = Mock(return_value=report_status)
        with (
            patch.object(runner.subprocess, "run", build),
            patch.object(runner.subprocess, "Popen", return_value=process) as popen,
            patch.object(runner, "report", event_report),
        ):
            result = runner.run_tests(
                self.package,
                self.events,
                skip_build=skip_build,
                filter_pattern=filter_pattern,
            )
        return result, build, popen, event_report

    def test_build_and_test_commands_use_exact_flags_and_budget_only_for_tests(self) -> None:
        process = self.make_process()
        order: list[str] = []
        build = Mock(
            side_effect=lambda *args, **kwargs: (
                order.append("build"), subprocess.CompletedProcess(args[0], 0)
            )[1]
        )
        event_report = Mock(return_value=0)
        with (
            patch.object(runner.subprocess, "run", build),
            patch.object(
                runner.subprocess,
                "Popen",
                side_effect=lambda *args, **kwargs: (order.append("launch"), process)[1],
            ) as popen,
            patch.object(runner, "report", event_report),
        ):
            result = runner.run_tests(
                self.package,
                self.events,
                skip_build=False,
                filter_pattern=None,
            )

        self.assertEqual(result, 0)
        self.assertEqual(order, ["build", "launch"])
        build.assert_called_once_with(
            ["swift", "build", "--package-path", str(self.package), "--build-tests"],
            check=False,
        )
        test_command = [
            "swift",
            "test",
            "--package-path",
            str(self.package),
            "--skip-build",
            "--event-stream-output-path",
            str(self.events),
            "--event-stream-version",
            "0",
        ]
        popen.assert_called_once_with(test_command, start_new_session=os.name == "posix")
        process.wait.assert_called_once_with()
        event_report.assert_called_once_with(self.events, enforce_budget=True)

    def test_skip_build_and_filter_are_forwarded_without_extra_flags(self) -> None:
        result, build, popen, event_report = self.run_with_mocks(
            skip_build=True,
            filter_pattern="Suite/testName",
        )

        self.assertEqual(result, 0)
        build.assert_not_called()
        command = popen.call_args.args[0]
        self.assertEqual(
            command,
            [
                "swift",
                "test",
                "--package-path",
                str(self.package),
                "--skip-build",
                "--event-stream-output-path",
                str(self.events),
                "--event-stream-version",
                "0",
                "--filter",
                "Suite/testName",
            ],
        )
        event_report.assert_called_once_with(self.events, enforce_budget=False)

    def test_positive_test_failure_is_preserved_when_report_succeeds(self) -> None:
        result, _, _, event_report = self.run_with_mocks(test_returncode=17)

        self.assertEqual(result, 17)
        event_report.assert_called_once_with(self.events, enforce_budget=True)

    def test_positive_test_failure_is_preserved_when_report_fails(self) -> None:
        result, _, _, event_report = self.run_with_mocks(test_returncode=17, report_status=1)

        self.assertEqual(result, 17)
        event_report.assert_called_once_with(self.events, enforce_budget=True)

    def test_successful_test_returns_failure_when_event_report_fails(self) -> None:
        result, _, _, event_report = self.run_with_mocks(report_status=1)

        self.assertEqual(result, 1)
        event_report.assert_called_once_with(self.events, enforce_budget=True)

    def test_signal_exit_maps_to_one_and_still_reports_events(self) -> None:
        result, _, _, event_report = self.run_with_mocks(test_returncode=-signal.SIGTERM)

        self.assertEqual(result, 1)
        event_report.assert_called_once_with(self.events, enforce_budget=True)

    def test_reporter_applies_budget_only_to_full_runs_after_wait(self) -> None:
        cases = (
            ("full-over-budget", None, 0, 1),
            ("filtered-over-budget", "Suite/testName", 0, 0),
            ("failed-full-over-budget", None, 17, 17),
        )
        for filename, filter_pattern, test_returncode, expected in cases:
            with self.subTest(filename=filename):
                event_path = self.root / "reports" / f"{filename}.jsonl"
                process = self.make_process(test_returncode)

                def launch(*args: object, **kwargs: object) -> Mock:
                    self.write_synthetic_events(
                        event_path,
                        event_reporter.SUITE_BUDGET_SECONDS + 1,
                    )
                    return process

                with (
                    patch.object(runner.subprocess, "Popen", side_effect=launch),
                    patch.object(runner, "_terminate_and_reap") as cleanup,
                    redirect_stderr(io.StringIO()),
                    redirect_stdout(io.StringIO()),
                ):
                    result = runner.run_tests(
                        self.package,
                        event_path,
                        skip_build=True,
                        filter_pattern=filter_pattern,
                    )

                self.assertEqual(result, expected)
                process.wait.assert_called_once_with()
                cleanup.assert_not_called()

    def test_keyboard_interrupt_cleans_up_and_reports(self) -> None:
        process = self.make_process(None)
        process.wait.side_effect = KeyboardInterrupt
        process.poll.return_value = None
        event_report = Mock(return_value=1)
        with (
            patch.object(runner.subprocess, "Popen", return_value=process),
            patch.object(runner, "_terminate_and_reap") as cleanup,
            patch.object(runner, "report", event_report),
            redirect_stderr(io.StringIO()),
        ):
            result = runner.run_tests(
                self.package,
                self.events,
                skip_build=True,
                filter_pattern=None,
            )

        self.assertEqual(result, 130)
        cleanup.assert_called_once_with(process, os.name)
        process.wait.assert_called_once_with()
        event_report.assert_called_once_with(self.events, enforce_budget=True)

    def test_sigterm_cleans_up_and_restores_previous_handler(self) -> None:
        process = self.make_process(None)

        def raise_sigterm() -> int:
            signal.raise_signal(signal.SIGTERM)
            return 0

        process.wait.side_effect = raise_sigterm
        process.poll.return_value = None
        event_report = Mock(return_value=1)
        previous_handler = signal.getsignal(signal.SIGTERM)
        with (
            patch.object(runner.subprocess, "Popen", return_value=process),
            patch.object(runner, "_terminate_and_reap") as cleanup,
            patch.object(runner, "report", event_report),
            redirect_stderr(io.StringIO()),
        ):
            result = runner.run_tests(
                self.package,
                self.events,
                skip_build=True,
                filter_pattern=None,
            )

        self.assertEqual(result, 130)
        self.assertIs(signal.getsignal(signal.SIGTERM), previous_handler)
        cleanup.assert_called_once_with(process, os.name)
        event_report.assert_called_once_with(self.events, enforce_budget=True)

    def test_cleanup_failure_still_reports_and_returns_one(self) -> None:
        process = self.make_process(None)
        process.wait.side_effect = KeyboardInterrupt
        event_report = Mock(return_value=0)
        with (
            patch.object(runner.subprocess, "Popen", return_value=process),
            patch.object(
                runner,
                "_terminate_and_reap",
                side_effect=OSError("cleanup failed"),
            ) as cleanup,
            patch.object(runner, "report", event_report),
            redirect_stderr(io.StringIO()),
        ):
            result = runner.run_tests(
                self.package,
                self.events,
                skip_build=True,
                filter_pattern=None,
            )

        self.assertEqual(result, 1)
        cleanup.assert_called_once_with(process, os.name)
        event_report.assert_called_once_with(self.events, enforce_budget=True)

    def test_posix_cleanup_kills_process_group_and_reaps_process(self) -> None:
        process = self.make_process(None)
        kill_signal = 9
        with (
            patch.object(runner.os, "killpg", create=True) as killpg,
            patch.object(runner.signal, "SIGKILL", kill_signal, create=True),
        ):
            runner._terminate_and_reap(process, "posix")

        killpg.assert_called_once_with(process.pid, kill_signal)
        process.wait.assert_called_once_with()

    def test_windows_cleanup_invokes_taskkill(self) -> None:
        process = self.make_process(None)
        with patch.object(runner.subprocess, "run") as taskkill:
            runner._terminate_and_reap(process, "nt")

        taskkill.assert_called_once_with(
            ["taskkill", "/PID", str(process.pid), "/T", "/F"],
            check=True,
        )
        process.wait.assert_called_once_with()

    def test_windows_cleanup_reaps_if_taskkill_fails_after_process_exit(self) -> None:
        failures = (
            subprocess.CalledProcessError(1, ["taskkill"]),
            OSError("taskkill failed"),
        )
        for failure in failures:
            with self.subTest(error=type(failure).__name__):
                process = self.make_process(0)
                with patch.object(runner.subprocess, "run", side_effect=failure) as taskkill:
                    runner._terminate_and_reap(process, "nt")

                taskkill.assert_called_once_with(
                    ["taskkill", "/PID", str(process.pid), "/T", "/F"],
                    check=True,
                )
                process.poll.assert_called_once_with()
                process.wait.assert_called_once_with()

    def test_windows_cleanup_raises_if_taskkill_fails_and_process_is_alive(self) -> None:
        failures = (
            subprocess.CalledProcessError(1, ["taskkill"]),
            OSError("taskkill failed"),
        )
        for failure in failures:
            with self.subTest(error=type(failure).__name__):
                process = self.make_process(None)
                with (
                    patch.object(runner.subprocess, "run", side_effect=failure),
                    self.assertRaises(type(failure)) as raised,
                ):
                    runner._terminate_and_reap(process, "nt")

                self.assertIs(raised.exception, failure)
                process.poll.assert_called_once_with()
                process.wait.assert_not_called()

    def test_existing_event_file_is_rejected_without_running_or_reporting(self) -> None:
        self.events.parent.mkdir(parents=True)
        self.events.write_text("stale\n", encoding="utf-8")
        build = Mock()
        popen = Mock()
        event_report = Mock()
        with (
            patch.object(runner.subprocess, "run", build),
            patch.object(runner.subprocess, "Popen", popen),
            patch.object(runner, "report", event_report),
        ):
            with self.assertRaisesRegex(runner.RunnerInputError, "already exists"):
                runner.run_tests(
                    self.package,
                    self.events,
                    skip_build=False,
                    filter_pattern=None,
                )
        build.assert_not_called()
        popen.assert_not_called()
        event_report.assert_not_called()
        self.assertEqual(self.events.read_text(encoding="utf-8"), "stale\n")

    def test_empty_filter_is_rejected_before_running(self) -> None:
        build = Mock()
        popen = Mock()
        with patch.object(runner.subprocess, "run", build), patch.object(
            runner.subprocess, "Popen", popen
        ):
            for pattern in ("", "  "):
                with redirect_stderr(io.StringIO()) as stderr:
                    status = runner.main(
                        [
                            "--package-path",
                            str(self.package),
                            "--event-stream-output-path",
                            str(self.events),
                            "--filter",
                            pattern,
                        ]
                    )
                self.assertEqual(status, 1)
                self.assertIn("test filter is empty", stderr.getvalue())
        build.assert_not_called()
        popen.assert_not_called()
        self.assertFalse(self.events.exists())

    def test_missing_package_is_rejected(self) -> None:
        with self.assertRaisesRegex(runner.RunnerInputError, "not a directory"):
            runner.run_tests(
                self.root / "missing",
                self.events,
                skip_build=True,
                filter_pattern=None,
            )

    def test_package_without_manifest_is_rejected(self) -> None:
        empty_package = self.root / "empty-package"
        empty_package.mkdir()
        with self.assertRaisesRegex(runner.RunnerInputError, "no Package.swift"):
            runner.run_tests(
                empty_package,
                self.events,
                skip_build=True,
                filter_pattern=None,
            )

    def test_failed_build_does_not_launch_or_report_tests(self) -> None:
        build = Mock(return_value=subprocess.CompletedProcess([], 9))
        popen = Mock()
        event_report = Mock()
        errors = io.StringIO()
        with (
            patch.object(runner.subprocess, "run", build),
            patch.object(runner.subprocess, "Popen", popen),
            patch.object(runner, "report", event_report),
            redirect_stderr(errors),
        ):
            result = runner.run_tests(
                self.package,
                self.events,
                skip_build=False,
                filter_pattern=None,
            )

        self.assertEqual(result, 9)
        popen.assert_not_called()
        event_report.assert_not_called()
        self.assertIn("Swift tests not run: test build failed", errors.getvalue())

    def test_failed_build_signal_maps_to_one_without_event_report(self) -> None:
        build = Mock(return_value=subprocess.CompletedProcess([], -signal.SIGTERM))
        event_report = Mock()
        with (
            patch.object(runner.subprocess, "run", build),
            patch.object(runner, "report", event_report),
            redirect_stderr(io.StringIO()),
        ):
            result = runner.run_tests(
                self.package,
                self.events,
                skip_build=False,
                filter_pattern=None,
            )

        self.assertEqual(result, 1)
        event_report.assert_not_called()

    def test_unsupported_platform_fails_before_build(self) -> None:
        build = Mock()
        with (
            patch.object(runner, "_check_platform", side_effect=RuntimeError("unsupported")),
            patch.object(runner.subprocess, "run", build),
            self.assertRaisesRegex(RuntimeError, "unsupported"),
        ):
            runner.run_tests(
                self.package,
                self.events,
                skip_build=False,
                filter_pattern=None,
            )
        build.assert_not_called()


if __name__ == "__main__":
    unittest.main()
