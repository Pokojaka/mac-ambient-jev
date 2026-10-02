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
    build_diarization_baseline_record,
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


def diarization_baseline_check(
    *,
    audio_path: pathlib.Path,
    speaker_reference: pathlib.Path,
    artifact_path: pathlib.Path,
    evaluation_path: pathlib.Path,
    output_path: pathlib.Path,
) -> CheckResult:
    output_path.unlink(missing_ok=True)
    for path in (
        audio_path,
        speaker_reference,
        artifact_path,
        evaluation_path,
    ):
        if not path.is_file():
            return CheckResult(
                "diarization-baseline-record",
                Status.SKIPPED_MISSING_DEPENDENCY,
                f"Required artifact {str(path)!r} is missing",
            )
    try:
        record = build_diarization_baseline_record(
            artifact_path=artifact_path,
            evaluation_path=evaluation_path,
            audio_path=audio_path,
            speaker_reference_path=speaker_reference,
        )
        record.write(output_path)
    except Exception as exc:
        return CheckResult(
            "diarization-baseline-record",
            Status.FAIL,
            f"{type(exc).__name__}: {exc}",
        )
    return CheckResult(
        "diarization-baseline-record",
        Status.PASS,
        str(output_path),
    )


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


def diarization_model_checks(
    *,
    here: pathlib.Path,
    audio_path: pathlib.Path,
    speaker_reference: pathlib.Path,
    work_root: pathlib.Path,
    device: str,
    profile: str,
    match_threshold: float,
    ambiguity_margin: float,
    min_clean_speech_ms: int,
) -> list[CheckResult]:
    work_root.mkdir(parents=True, exist_ok=True)

    nemotron_output = work_root / "nemotron3.json"
    diarization_evaluation_output = (
        work_root / "diarization-evaluation.json"
    )
    diarization_baseline_output = (
        work_root / "nemotron3-current.json"
    )
    nemotron_output.unlink(missing_ok=True)
    diarization_evaluation_output.unlink(missing_ok=True)
    root = here.parents[1]

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
            "--profile",
            profile,
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
            "--output",
            str(diarization_evaluation_output),
        ],
        root,
        executables=("swift",),
        paths=(
            speaker_reference,
            nemotron_output,
        ),
        outputs=(diarization_evaluation_output,),
    )

    diarization_baseline = diarization_baseline_check(
        audio_path=audio_path,
        speaker_reference=speaker_reference,
        artifact_path=nemotron_output,
        evaluation_path=diarization_evaluation_output,
        output_path=diarization_baseline_output,
    )

    return [
        nemotron,
        diarization_evaluator,
        diarization_baseline,
    ]


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
    parser.add_argument(
        "--with-diarization",
        action="store_true",
        help="add the post-V1 Nemotron diarization checks to --full",
    )
    parser.add_argument("--full-speaker-reference", type=pathlib.Path)
    parser.add_argument("--diarization-profile")
    parser.add_argument("--speaker-match-threshold", type=float)
    parser.add_argument("--speaker-ambiguity-margin", type=float)
    parser.add_argument("--min-clean-speech-ms", type=int)
    args = parser.parse_args(argv)

    full_options = {
        "--full-audio": args.full_audio,
        "--full-asr-reference-verbatim":
            args.full_asr_reference_verbatim,
        "--work-root": args.work_root,
        "--device": args.device,
    }
    diarization_options = {
        "--full-speaker-reference": args.full_speaker_reference,
        "--diarization-profile": args.diarization_profile,
        "--speaker-match-threshold": args.speaker_match_threshold,
        "--speaker-ambiguity-margin": args.speaker_ambiguity_margin,
        "--min-clean-speech-ms": args.min_clean_speech_ms,
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
        if given or args.with_diarization:
            parser.error(
                f"{', '.join(given or ['--with-diarization'])} "
                "requires --full"
            )
    if args.with_diarization:
        missing = [
            name
            for name, value in diarization_options.items()
            if value is None
        ]
        if missing:
            parser.error(
                f"--with-diarization requires {', '.join(missing)}"
            )
    else:
        given = [
            name
            for name, value in diarization_options.items()
            if value is not None
        ]
        if given:
            parser.error(
                f"{', '.join(given)} requires --with-diarization"
            )

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
    if args.with_diarization:
        checks.extend(
            diarization_model_checks(
                here=here,
                audio_path=args.full_audio,
                speaker_reference=args.full_speaker_reference,
                work_root=args.work_root,
                device=args.device,
                profile=args.diarization_profile,
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
        write_json_atomic(args.json, payload)
    return summary.exit_code


if __name__ == "__main__":
    raise SystemExit(main())
