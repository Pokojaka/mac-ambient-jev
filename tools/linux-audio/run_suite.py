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


def optional_command_check(
    name: str,
    command: list[str],
    cwd: pathlib.Path,
    *,
    modules: tuple[str, ...] = (),
    executables: tuple[str, ...] = (),
    paths: tuple[pathlib.Path, ...] = (),
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
    return run_command(
        name,
        command,
        cwd,
    )


def full_model_checks(
    *,
    here: pathlib.Path,
    audio_path: pathlib.Path,
    speaker_reference: pathlib.Path,
    work_root: pathlib.Path,
    device: str,
    match_threshold: float | None,
    ambiguity_margin: float | None,
    min_clean_speech_ms: int | None,
) -> list[CheckResult]:
    work_root.mkdir(
        parents=True,
        exist_ok=True,
    )

    qwen_output = work_root / "qwen3-asr.json"
    nemotron_output = work_root / "nemotron3.json"
    qwen_output.unlink(missing_ok=True)
    nemotron_output.unlink(missing_ok=True)
    qwen = optional_command_check(
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

    if (
        match_threshold is None
        or ambiguity_margin is None
        or min_clean_speech_ms is None
    ):
        nemotron = CheckResult(
            "nemotron3-runner",
            Status.SKIPPED_MISSING_DEPENDENCY,
            (
                "calibrated speaker match threshold, ambiguity "
                "margin, and minimum clean speech duration are required"
            ),
        )
    else:
        nemotron = optional_command_check(
            "nemotron3-runner",
            [
                sys.executable,
                "-m",
                "diarization.nemotron3",
                str(audio_path),
                "--output",
                str(nemotron_output),
                "--device",
                device,
                "--match-threshold",
                str(match_threshold),
                "--ambiguity-margin",
                str(ambiguity_margin),
                "--min-clean-speech-ms",
                str(min_clean_speech_ms),
            ],
            here,
            modules=(
                "nemo",
                "huggingface_hub",
                "torch",
            ),
            paths=(audio_path,),
        )

    root = here.parents[1]
    diarization_evaluator = optional_command_check(
        "diarization-evaluator",
        [
            "swift",
            "run",
            "--package-path",
            str(root / "app" / "MacAmbientJev"),
            "MacAmbientJevEvaluateDiarization",
            str(speaker_reference),
            str(nemotron_output),
        ],
        root,
        executables=("swift",),
        paths=(
            speaker_reference,
            nemotron_output,
        ),
    )

    return [
        qwen,
        nemotron,
        diarization_evaluator,
    ]


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

    default_cache = (
        pathlib.Path.home()
        / ".cache"
        / "mac-ambient-jev"
        / "linux-audio"
    )
    parser.add_argument(
        "--full-audio",
        type=pathlib.Path,
        default=(
            default_cache
            / "voicevox"
            / "speakers-10"
            / "audio.wav"
        ),
    )
    parser.add_argument(
        "--full-speaker-reference",
        type=pathlib.Path,
    )
    parser.add_argument(
        "--work-root",
        type=pathlib.Path,
        default=default_cache / "results",
    )
    parser.add_argument(
        "--device",
        default="cuda:0",
    )
    parser.add_argument(
        "--speaker-match-threshold",
        type=float,
    )
    parser.add_argument(
        "--speaker-ambiguity-margin",
        type=float,
    )
    parser.add_argument(
        "--min-clean-speech-ms",
        type=int,
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
        speaker_reference = (
            args.full_speaker_reference
            if args.full_speaker_reference is not None
            else args.full_audio.with_name(
                "speaker-reference.json"
            )
        )
        checks.extend(
            full_model_checks(
                here=here,
                audio_path=args.full_audio,
                speaker_reference=speaker_reference,
                work_root=args.work_root,
                device=args.device,
                match_threshold=args.speaker_match_threshold,
                ambiguity_margin=args.speaker_ambiguity_margin,
                min_clean_speech_ms=args.min_clean_speech_ms,
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
