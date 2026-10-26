#!/usr/bin/env python3
"""Run SwiftPM tests and report Swift Testing events."""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import os
from pathlib import Path
import signal
import subprocess
import sys
from typing import Iterator

from report_test_events import report


class RunnerInputError(ValueError):
    """A required package or event-stream path is invalid."""


def _absolute_package_path(path: Path) -> Path:
    package_path = Path(path).resolve()
    if not package_path.is_dir():
        raise RunnerInputError(f"package path is not a directory: {package_path}")
    if not (package_path / "Package.swift").is_file():
        raise RunnerInputError(f"package path has no Package.swift: {package_path}")
    return package_path


def _absolute_event_path(path: Path) -> Path:
    event_path = Path(os.path.abspath(Path(path)))
    if event_path.exists() or event_path.is_symlink():
        raise RunnerInputError(
            f"event stream already exists: {event_path}; select a unique output filename"
        )
    try:
        event_path.parent.mkdir(parents=True, exist_ok=True)
    except OSError as error:
        raise RunnerInputError(
            f"cannot create event stream directory {event_path.parent}: {error}"
        ) from error
    if event_path.exists() or event_path.is_symlink():
        raise RunnerInputError(
            f"event stream already exists: {event_path}; select a unique output filename"
        )
    return event_path


def _check_platform(platform_name: str) -> None:
    if platform_name not in ("posix", "nt"):
        raise RuntimeError(f"unsupported platform for Swift test process cleanup: {platform_name}")


@contextmanager
def _sigterm_as_keyboard_interrupt() -> Iterator[None]:
    previous_handler = signal.getsignal(signal.SIGTERM)

    def interrupt(signum: int, frame: object) -> None:
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupt)
    try:
        yield
    finally:
        signal.signal(signal.SIGTERM, previous_handler)


def _terminate_and_reap(process: subprocess.Popen[bytes], platform_name: str) -> None:
    if platform_name == "posix":
        os.killpg(process.pid, signal.SIGKILL)
    elif platform_name == "nt":
        try:
            subprocess.run(
                ["taskkill", "/PID", str(process.pid), "/T", "/F"],
                check=True,
            )
        except (subprocess.CalledProcessError, OSError):
            if process.poll() is None:
                raise
    else:
        raise RuntimeError(
            f"unsupported platform for Swift test process cleanup: {platform_name}"
        )
    process.wait()


def _run_test_process(
    command: list[str],
    event_path: Path,
    *,
    enforce_budget: bool,
) -> int:
    process: subprocess.Popen[bytes] | None = None
    report_status = 1
    interrupted = False
    cleanup_failed = False

    with _sigterm_as_keyboard_interrupt():
        process = subprocess.Popen(
            command,
            start_new_session=os.name == "posix",
        )
        try:
            process.wait()
        except KeyboardInterrupt:
            interrupted = True
            print("Swift tests interrupted; terminating the process tree.", file=sys.stderr)
        finally:
            try:
                if process.poll() is None:
                    _terminate_and_reap(process, os.name)
            except Exception as error:
                cleanup_failed = True
                print(f"ERROR: failed to clean up Swift test process tree: {error}", file=sys.stderr)
            finally:
                report_status = report(event_path, enforce_budget=enforce_budget)

    if cleanup_failed:
        return 1
    if interrupted:
        return 130
    if process.returncode is None or process.returncode < 0:
        return 1
    if process.returncode > 0:
        return process.returncode
    return 0 if report_status == 0 else 1


def run_tests(
    package_path: Path,
    event_path: Path,
    *,
    skip_build: bool,
    filter_pattern: str | None,
) -> int:
    """Build and run Swift tests, returning the command or report status."""
    _check_platform(os.name)
    if filter_pattern is not None and not filter_pattern.strip():
        raise RunnerInputError("test filter is empty; omit --filter to run the full suite")
    package = _absolute_package_path(package_path)
    events = _absolute_event_path(event_path)

    if not skip_build:
        build = subprocess.run(
            ["swift", "build", "--package-path", str(package), "--build-tests"],
            check=False,
        )
        if build.returncode != 0:
            print("Swift tests not run: test build failed", file=sys.stderr)
            return build.returncode if build.returncode > 0 else 1

    command = [
        "swift",
        "test",
        "--package-path",
        str(package),
        "--skip-build",
        "--event-stream-output-path",
        str(events),
        "--event-stream-version",
        "0",
    ]
    if filter_pattern is not None:
        command.extend(["--filter", filter_pattern])
    return _run_test_process(
        command,
        events,
        enforce_budget=filter_pattern is None,
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package-path", type=Path, required=True)
    parser.add_argument("--event-stream-output-path", type=Path, required=True)
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--filter", dest="filter_pattern")
    arguments = parser.parse_args(argv)
    try:
        return run_tests(
            arguments.package_path,
            arguments.event_stream_output_path,
            skip_build=arguments.skip_build,
            filter_pattern=arguments.filter_pattern,
        )
    except (OSError, RuntimeError, RunnerInputError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
