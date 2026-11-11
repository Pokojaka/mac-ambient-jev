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

from common.baseline import (
    REFERENCE_KINDS,
    build_asr_baseline_record,
)
from common.files import write_json_atomic


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


def optional_command_check(
    name: str,
    command: list[str],
    cwd: pathlib.Path,
    *,
    modules: tuple[str, ...] = (),
    executables: tuple[str, ...] = (),
    paths: tuple[pathlib.Path, ...] = (),
    outputs: tuple[pathlib.Path, ...] = (),
) -> CheckResult:
    for module in modules:
        if importlib.util.find_spec(module) is None:
            return CheckResult(
                name,
                Status.SKIPPED_MISSING_DEPENDENCY,
                f"Python module {module!r} is not installed",
            )
    for executable in executables:
        if shutil.which(executable) is None:
            return CheckResult(
                name,
                Status.SKIPPED_MISSING_DEPENDENCY,
                f"Executable {executable!r} is not installed",
            )
    for path in paths:
        if not path.is_file():
            return CheckResult(
                name,
                Status.SKIPPED_MISSING_DEPENDENCY,
                f"Required fixture {str(path)!r} is missing",
            )
    result = run_command(
        name,
        command,
        cwd,
    )
    if result.status is not Status.PASS:
        return result
    for output in outputs:
        if not output.is_file():
            return CheckResult(
                name,
                Status.FAIL,
                f"Expected output {str(output)!r} was not produced",
            )
    return result



def asr_baseline_check(
    *,
    name: str,
    audio_path: pathlib.Path,
    reference_path: pathlib.Path,
    reference_kind: str,
    artifact_path: pathlib.Path,
    evaluation_path: pathlib.Path,
    output_path: pathlib.Path,
) -> CheckResult:
    output_path.unlink(missing_ok=True)
    for path in (
        audio_path,
        reference_path,
        artifact_path,
        evaluation_path,
    ):
        if not path.is_file():
            return CheckResult(
                name,
                Status.SKIPPED_MISSING_DEPENDENCY,
                f"Required artifact {str(path)!r} is missing",
            )
    try:
        record = build_asr_baseline_record(
            artifact_path=artifact_path,
            evaluation_path=evaluation_path,
            audio_path=audio_path,
            reference_path=reference_path,
            reference_kind=reference_kind,
        )
        record.write(output_path)
    except Exception as exc:
        return CheckResult(
            name,
            Status.FAIL,
            f"{type(exc).__name__}: {exc}",
        )
    return CheckResult(name, Status.PASS, str(output_path))


def asr_model_checks(
    *,
    here: pathlib.Path,
    audio_path: pathlib.Path,
    asr_references: dict[str, pathlib.Path],
    work_root: pathlib.Path,
    device: str,
) -> list[CheckResult]:
    """Runs Qwen3-ASR once and scores it against each reference kind.

    The verbatim reference is the primary CER; a content reference, when
    given, is scored as a supplementary CER.
    """
    if "verbatim" not in asr_references:
        raise ValueError("a verbatim ASR reference is required")
    unknown = set(asr_references) - set(REFERENCE_KINDS)
    if unknown:
        raise ValueError(f"unknown ASR reference kinds: {sorted(unknown)}")
    work_root.mkdir(parents=True, exist_ok=True)

    qwen_output = work_root / "qwen3-asr.json"
    qwen_output.unlink(missing_ok=True)
    checks = [
        optional_command_check(
            "qwen3-asr-runner",
            [
                sys.executable,
                "-m",
                "asr.qwen3_asr",
                str(audio_path),
                "--output",
                str(qwen_output),
                "--device",
                device,
                "--language",
                "Japanese",
            ],
            here,
            modules=("qwen_asr", "torch"),
            paths=(audio_path,),
        )
    ]

    root = here.parents[1]
    for kind in REFERENCE_KINDS:
        if kind not in asr_references:
            continue
        reference = asr_references[kind]
        evaluation_output = work_root / f"asr-evaluation-{kind}.json"
        baseline_output = work_root / f"qwen3-asr-{kind}-current.json"
        evaluation_output.unlink(missing_ok=True)
        checks.append(
            optional_command_check(
                f"asr-evaluator-{kind}",
                [
                    "swift",
                    "run",
                    "--package-path",
                    str(root / "app" / "MacAmbientJev"),
                    "MacAmbientJevEvaluateASR",
                    str(reference),
                    str(qwen_output),
                    "--output",
                    str(evaluation_output),
                ],
                root,
                executables=("swift",),
                paths=(reference, qwen_output),
                outputs=(evaluation_output,),
            )
        )
        checks.append(
            asr_baseline_check(
                name=f"asr-baseline-{kind}",
                audio_path=audio_path,
                reference_path=reference,
                reference_kind=kind,
                artifact_path=qwen_output,
                evaluation_path=evaluation_output,
                output_path=baseline_output,
            )
        )
    return checks


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group(
        required=True
    )
    mode.add_argument("--smoke", action="store_true")
    mode.add_argument("--full", action="store_true")
    parser.add_argument("--json", type=pathlib.Path)
    parser.add_argument("--full-audio", type=pathlib.Path)
    parser.add_argument(
        "--full-asr-reference-verbatim",
        type=pathlib.Path,
        help="primary CER reference",
    )
    parser.add_argument(
        "--full-asr-reference-content",
        type=pathlib.Path,
        help="supplementary CER reference without fillers",
    )
    parser.add_argument("--work-root", type=pathlib.Path)
    parser.add_argument("--device")
    args = parser.parse_args(argv)

    full_options = {
        "--full-audio": args.full_audio,
        "--full-asr-reference-verbatim":
            args.full_asr_reference_verbatim,
        "--work-root": args.work_root,
        "--device": args.device,
    }
    if args.full:
        missing = [name for name, value in full_options.items() if value is None]
        if missing:
            parser.error(f"--full requires {', '.join(missing)}")
    else:
        given = [
            name
            for name, value in (
                full_options
                | {"--full-asr-reference-content":
                    args.full_asr_reference_content}
            ).items()
            if value is not None
        ]
        if given:
            parser.error(f"{', '.join(given)} requires --full")

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
        asr_references = {"verbatim": args.full_asr_reference_verbatim}
        if args.full_asr_reference_content is not None:
            asr_references["content"] = args.full_asr_reference_content
        checks.extend(
            asr_model_checks(
                here=here,
                audio_path=args.full_audio,
                asr_references=asr_references,
                work_root=args.work_root,
                device=args.device,
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
        write_json_atomic(args.json, payload)
    return summary.exit_code


if __name__ == "__main__":
    raise SystemExit(main())
