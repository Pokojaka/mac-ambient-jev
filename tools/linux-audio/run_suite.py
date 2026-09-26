from __future__ import annotations

import argparse
import importlib.util
import json
import pathlib
import shutil
import subprocess
import sys
from dataclasses import dataclass
from enum import Enum


class Status(str, Enum):
    PASS = "PASS"
    FAIL = "FAIL"
    SKIPPED_MISSING_DEPENDENCY = "SKIPPED_MISSING_DEPENDENCY"


@dataclass(frozen=True)
class CheckResult:
    name: str
    status: Status
    detail: str | None = None

    def to_dict(self) -> dict:
        payload = {
            "name": self.name,
            "status": self.status.value,
        }
        if self.detail:
            payload["detail"] = self.detail
        return payload


@dataclass(frozen=True)
class SuiteSummary:
    overall: Status
    exit_code: int
    checks: tuple[CheckResult, ...]

    def to_dict(self) -> dict:
        return {
            "overall": self.overall.value,
            "exit_code": self.exit_code,
            "checks": [
                check.to_dict()
                for check in self.checks
            ],
        }


def summarize(checks: list[CheckResult]) -> SuiteSummary:
    if any(
        check.status is Status.FAIL
        for check in checks
    ):
        overall, code = Status.FAIL, 1
    elif any(
        check.status
        is Status.SKIPPED_MISSING_DEPENDENCY
        for check in checks
    ):
        overall = Status.SKIPPED_MISSING_DEPENDENCY
        code = 2
    else:
        overall, code = Status.PASS, 0
    return SuiteSummary(
        overall,
        code,
        tuple(checks),
    )


def run_command(
    name: str,
    command: list[str],
    cwd: pathlib.Path,
) -> CheckResult:
    completed = subprocess.run(
        command,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    return CheckResult(
        name,
        Status.PASS
        if completed.returncode == 0
        else Status.FAIL,
        completed.stdout.strip() or None,
    )


def optional_import_check(
    name: str,
    module: str,
) -> CheckResult:
    if importlib.util.find_spec(module) is None:
        return CheckResult(
            name,
            Status.SKIPPED_MISSING_DEPENDENCY,
            f"Python module {module!r} is not installed",
        )
    return CheckResult(name, Status.PASS)


def optional_executable_check(
    name: str,
    executable: str,
) -> CheckResult:
    if shutil.which(executable) is None:
        return CheckResult(
            name,
            Status.SKIPPED_MISSING_DEPENDENCY,
            f"Executable {executable!r} is not installed",
        )
    return CheckResult(name, Status.PASS)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group(
        required=True
    )
    mode.add_argument("--smoke", action="store_true")
    mode.add_argument("--full", action="store_true")
    parser.add_argument(
        "--json",
        type=pathlib.Path,
    )
    args = parser.parse_args(argv)

    here = pathlib.Path(__file__).resolve().parent
    root = here.parents[1]
    checks = [
        run_command(
            "portable-core",
            ["bash", "scripts/verify_portable.sh"],
            root,
        ),
        run_command(
            "python-unit-tests",
            [
                sys.executable,
                "-m",
                "pytest",
                "-q",
                "tests",
            ],
            here,
        ),
        optional_executable_check(
            "ffmpeg",
            "ffmpeg",
        ),
        optional_import_check(
            "qwen3-asr-model",
            "qwen_asr",
        ),
    ]
    if args.full:
        checks.append(
            optional_import_check(
                "nemotron3-model",
                "nemo",
            )
        )

    summary = summarize(checks)
    payload = summary.to_dict()
    print(
        json.dumps(
            payload,
            ensure_ascii=False,
            indent=2,
        )
    )
    if args.json:
        args.json.parent.mkdir(
            parents=True,
            exist_ok=True,
        )
        args.json.write_text(
            json.dumps(
                payload,
                ensure_ascii=False,
                indent=2,
            ) + "\n",
            encoding="utf-8",
        )
    return summary.exit_code


if __name__ == "__main__":
    raise SystemExit(main())
