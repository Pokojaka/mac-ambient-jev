"""Scores diarization run files with the repository's standard-DER evaluator.

Two modes, exactly one per call:
  --reference-run RUN --hypothesis-run RUN   DER of the hypothesis against the reference.
  --runs RUN RUN [RUN ...]                    DER of every ordered pair among repeated runs
                                              (self-disagreement of one engine).

A run file is the JSON written by MacAmbientJevDiarizeFile or MacAmbientJevDiarizeFileOracle.
Both runs of a pair must carry the same audio SHA-256 and sample count. The evaluator reads the
raw cluster spans; the collapsed display metrics are intentionally not scored.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
from collections.abc import Callable
from pathlib import Path

REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
PACKAGE = REPOSITORY_ROOT / "app" / "MacAmbientJev"
FRAMES_PER_MILLISECOND = 16  # 16 kHz canonical audio
RUN_SCHEMA_VERSION = 1
ARTIFACT_SCHEMA_VERSION = 2

Evaluator = Callable[[list[dict], dict], dict]


class ComparisonError(Exception):
    pass


def frame_to_ms(frame: int) -> int:
    """Exact integer division by 16, rounding half to even."""
    quotient, remainder = divmod(frame, FRAMES_PER_MILLISECOND)
    twice = remainder * 2
    if twice > FRAMES_PER_MILLISECOND or (twice == FRAMES_PER_MILLISECOND and quotient % 2 == 1):
        return quotient + 1
    return quotient


def load_run(path: Path) -> dict:
    try:
        run = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise ComparisonError(f"cannot read run file {path}: {error}") from error
    if run.get("schema_version") != RUN_SCHEMA_VERSION:
        raise ComparisonError(f"{path}: schema_version must be {RUN_SCHEMA_VERSION}")
    for key in ("audio", "raw_spans", "raw_speaker_count", "provenance"):
        if key not in run:
            raise ComparisonError(f"{path}: missing key {key}")
    return run


def require_same_audio(first: dict, second: dict, first_path: Path, second_path: Path) -> None:
    if first["audio"] != second["audio"]:
        raise ComparisonError(
            f"audio mismatch: {first_path} has {first['audio']}, {second_path} has {second['audio']}"
        )


def raw_spans(run: dict, path: Path) -> list[dict]:
    spans = []
    for index, span in enumerate(run["raw_spans"]):
        start, end = frame_to_ms(span["start_frame"]), frame_to_ms(span["end_frame"])
        if not 0 <= start < end:
            raise ComparisonError(
                f"{path}: raw span {index} is empty or negative after conversion to milliseconds "
                f"({span['start_frame']}..{span['end_frame']} frames)"
            )
        spans.append({"start_ms": start, "end_ms": end, "speaker_label": span["speaker_id"]})
    return spans


def speaker_count(run: dict, path: Path) -> int:
    count = len({span["speaker_id"] for span in run["raw_spans"]})
    if count != run["raw_speaker_count"]:
        raise ComparisonError(f"{path}: raw_speaker_count disagrees with its raw spans")
    return count


def swift_evaluator(min_clean_speech_ms: int) -> Evaluator:
    def evaluate(reference: list[dict], hypothesis: list[dict]) -> dict:
        artifact = {
            "schema_version": ARTIFACT_SCHEMA_VERSION,
            "spans": [],
            "raw_spans": hypothesis,
            "overflow_resolver": {"min_clean_speech_ms": min_clean_speech_ms},
        }
        with tempfile.TemporaryDirectory() as scratch:
            reference_path = Path(scratch) / "reference.json"
            artifact_path = Path(scratch) / "artifact.json"
            reference_path.write_text(json.dumps(reference), encoding="utf-8")
            artifact_path.write_text(json.dumps(artifact), encoding="utf-8")
            completed = subprocess.run(
                [
                    "swift", "run", "--package-path", str(PACKAGE),
                    "MacAmbientJevEvaluateDiarization", str(reference_path), str(artifact_path),
                ],
                capture_output=True,
                text=True,
            )
        if completed.returncode != 0:
            raise ComparisonError(f"MacAmbientJevEvaluateDiarization failed:\n{completed.stderr}")
        return json.loads(completed.stdout)["standard"]

    return evaluate


def compare(reference_path: Path, hypothesis_path: Path, evaluate: Evaluator) -> dict:
    reference, hypothesis = load_run(reference_path), load_run(hypothesis_path)
    require_same_audio(reference, hypothesis, reference_path, hypothesis_path)
    return {
        "audio": reference["audio"],
        "reference_provenance": reference["provenance"],
        "hypothesis_provenance": hypothesis["provenance"],
        "reference_speaker_count": speaker_count(reference, reference_path),
        "hypothesis_speaker_count": speaker_count(hypothesis, hypothesis_path),
        "standard": evaluate(raw_spans(reference, reference_path), raw_spans(hypothesis, hypothesis_path)),
    }


def self_disagreement(paths: list[Path], evaluate: Evaluator) -> dict:
    pairs = []
    for index, reference_path in enumerate(paths):
        for hypothesis_path in paths[index + 1:]:
            result = compare(reference_path, hypothesis_path, evaluate)
            pairs.append({
                "reference_run": str(reference_path),
                "hypothesis_run": str(hypothesis_path),
                "reference_speaker_count": result["reference_speaker_count"],
                "hypothesis_speaker_count": result["hypothesis_speaker_count"],
                "standard": result["standard"],
            })
    return {"run_count": len(paths), "pairs": pairs, "max_der": max(pair["standard"]["der"] for pair in pairs)}


def write_new(path: Path, payload: dict) -> None:
    with path.open("x", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")


def parse_arguments(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--reference-run", type=Path)
    parser.add_argument("--hypothesis-run", type=Path)
    parser.add_argument("--runs", type=Path, nargs="+")
    parser.add_argument("--min-clean-speech-ms", type=int, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    pair_mode = args.reference_run is not None and args.hypothesis_run is not None and args.runs is None
    runs_mode = args.runs is not None and args.reference_run is None and args.hypothesis_run is None
    if pair_mode == runs_mode:
        parser.error("give either --reference-run with --hypothesis-run, or --runs")
    if runs_mode and len(args.runs) < 2:
        parser.error("--runs needs at least two run files")
    if args.min_clean_speech_ms <= 0:
        parser.error("--min-clean-speech-ms must be positive")
    return args


def main(argv: list[str]) -> int:
    args = parse_arguments(argv)
    try:
        evaluate = swift_evaluator(args.min_clean_speech_ms)
        if args.runs is not None:
            payload = self_disagreement(args.runs, evaluate)
        else:
            payload = compare(args.reference_run, args.hypothesis_run, evaluate)
        write_new(args.output, payload)
    except (ComparisonError, FileExistsError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
