"""End-to-end acceptance driver for the portable MacAmbientJevProcessRecording CLI.

Runs the release executable on the public VOICEVOX long fixture with real models:
import (--keep-session --with-decisions), inspect with every model variable removed,
then resume of the completed session. Every check fails loudly; nothing is defaulted.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import uuid
import wave
from pathlib import Path
from typing import Any

REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
WINDOWS_DOC = REPOSITORY_ROOT / "docs" / "windows.md"
QWEN3_MANIFEST = (
    REPOSITORY_ROOT
    / "app/MacAmbientJev/Sources/MacAmbientJevPortableRuntime/Resources/qwen3_asr_models.json"
)

SILERO_VARIABLE = "MAC_AMBIENT_JEV_SILERO_MODEL"
QWEN3_DIRECTORY_VARIABLE = "QWEN3_ASR_ONNX_MODEL_DIRECTORY"
QWEN3_SIZE_VARIABLE = "QWEN3_ASR_ONNX_MODEL_SIZE"
DIARIZATION_VARIABLE = "MAC_AMBIENT_JEV_DIARIZATION_ONNX_MODEL_DIRECTORY"
CLAUSE_TAGGER_VARIABLE = "MAC_AMBIENT_JEV_CLAUSE_TAGGER_MODEL_DIRECTORY"
MODEL_VARIABLES = (
    SILERO_VARIABLE,
    QWEN3_DIRECTORY_VARIABLE,
    QWEN3_SIZE_VARIABLE,
    DIARIZATION_VARIABLE,
    CLAUSE_TAGGER_VARIABLE,
)

THREADS = 2
MAX_NORMALIZED_CER = 0.15
IMPORT_TIMEOUT_SECONDS = 300
RESUME_TIMEOUT_SECONDS = 300
INSPECT_TIMEOUT_SECONDS = 60
EVALUATOR_TIMEOUT_SECONDS = 60
EVENT_SCHEMA_VERSION = 3
SAMPLE_RATE = 16_000

INDIVIDUAL_SPEAKER_LIMIT = 7
VALID_LABELS = {f"Speaker {n}" for n in range(1, INDIVIDUAL_SPEAKER_LIMIT + 1)} | {
    "OTHER",
    "UNKNOWN",
}

# active_runs key -> (stage name in processing.run.* payloads, expected provenance engine)
STAGES = {
    "segmentation": ("segmentation", "onnxruntime-silero-vad"),
    "asr": ("asr", "onnxruntime-qwen3-asr"),
    "diarization": ("diarization", "onnxruntime-community1-diarizer"),
    "clause_boundary": ("clauseBoundary", None),
    "content_priority": ("contentPriority", None),
}
SEGMENT_KEYS = {
    "segment_id",
    "source",
    "start_ms",
    "end_ms",
    "text",
    "display_text",
    "speakers",
    "clause_state",
    "clause_slices",
}
JAPANESE_SCRIPT = re.compile(r"[぀-ヿ㐀-鿿]")
SESSION_ID_LINE = re.compile(r"^session_id: ([0-9A-Fa-f-]{36})$", re.MULTILINE)


class AcceptanceFailure(Exception):
    """An acceptance check failed."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AcceptanceFailure(message)


def is_int(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def load_json(path: Path) -> Any:
    require(path.is_file(), f"missing file: {path}")
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise AcceptanceFailure(f"unreadable JSON {path}: {error}") from error


# --- inputs -----------------------------------------------------------------


def require_model_environment(environment: dict[str, str]) -> dict[str, str]:
    values: dict[str, str] = {}
    for name in MODEL_VARIABLES:
        value = environment.get(name)
        require(value is not None and value != "", f"{name} is required")
        values[name] = value
    require(
        values[QWEN3_SIZE_VARIABLE] in {"0.6b", "1.7b"},
        f"{QWEN3_SIZE_VARIABLE} must be exactly 0.6b or 1.7b",
    )
    for name in MODEL_VARIABLES:
        if name == QWEN3_SIZE_VARIABLE:
            continue
        path = Path(values[name])
        require(path.is_absolute(), f"{name} must be an absolute path")
        if name == SILERO_VARIABLE:
            require(path.is_file(), f"{name} must name an existing file")
        else:
            require(path.is_dir(), f"{name} must name an existing directory")
    return values


def require_executable(path: Path, label: str) -> Path:
    require(path.is_absolute(), f"{label} must be an absolute path: {path}")
    require(path.is_file(), f"{label} does not exist: {path}")
    return path


def load_reference(doc: Path = WINDOWS_DOC) -> tuple[str, str, int]:
    """Reference text, WAV SHA-256 and sample count of the long fixture from docs/windows.md."""
    require(doc.is_file(), f"missing document: {doc}")
    rows = [
        line
        for line in doc.read_text(encoding="utf-8").splitlines()
        if line.startswith("| long |")
    ]
    require(len(rows) == 1, f"{doc} must hold exactly one '| long |' fixture row")
    cells = [cell.strip() for cell in rows[0].strip().strip("|").split("|")]
    require(len(cells) == 6, f"unexpected fixture row shape in {doc}")
    reference = cells[1]
    samples = int(cells[3].replace(",", ""))
    sha256 = cells[5].strip("`")
    require(reference != "" and re.fullmatch(r"[0-9a-f]{64}", sha256) is not None, "bad fixture row")
    return reference, sha256, samples


def inspect_fixture(fixture: Path, expected_sha256: str, expected_samples: int) -> int:
    """Verify the fixture and return its duration in milliseconds."""
    require(fixture.is_file(), f"missing fixture: {fixture}")
    require(
        hashlib.sha256(fixture.read_bytes()).hexdigest() == expected_sha256,
        f"fixture SHA-256 differs from docs/windows.md: {fixture}",
    )
    with wave.open(str(fixture), "rb") as audio:
        require(
            audio.getframerate() == SAMPLE_RATE and audio.getnchannels() == 1,
            "fixture must be 16 kHz mono",
        )
        require(audio.getnframes() == expected_samples, "fixture sample count differs from docs")
    return round(expected_samples * 1000 / SAMPLE_RATE)


def expected_asr_model(size: str, manifest: Path = QWEN3_MANIFEST) -> str:
    entry = load_json(manifest).get(size)
    require(isinstance(entry, dict), f"{manifest} has no model size {size}")
    return f"{entry['repository']}@{entry['commit']}"


# --- subprocess -------------------------------------------------------------


def run_command(
    arguments: list[str], environment: dict[str, str], timeout: int, label: str
) -> subprocess.CompletedProcess[str]:
    try:
        result = subprocess.run(
            arguments,
            env=environment,
            capture_output=True,
            text=True,
            encoding="utf-8",
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as error:
        raise AcceptanceFailure(f"{label} timed out after {timeout} s") from error
    require(
        result.returncode == 0,
        f"{label} exited with {result.returncode}\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}",
    )
    return result


def parse_session_id(stdout: str) -> str:
    matches = SESSION_ID_LINE.findall(stdout)
    require(len(matches) == 1, f"import stdout must hold exactly one session_id line, got {len(matches)}")
    try:
        return str(uuid.UUID(matches[0]))
    except ValueError as error:
        raise AcceptanceFailure(f"invalid session_id {matches[0]!r}") from error


def find_session_directory(root: Path, session_id: str) -> Path:
    found = []
    for child in root.iterdir():
        manifest = child / "session.json"
        if not manifest.is_file():
            continue
        try:
            value = json.loads(manifest.read_text(encoding="utf-8"))["session_id"]
            if str(uuid.UUID(value)) == session_id:
                found.append(child)
        except (ValueError, KeyError, TypeError) as error:
            raise AcceptanceFailure(f"unreadable session manifest {manifest}: {error}") from error
    require(len(found) == 1, f"expected exactly one session folder for {session_id}, found {len(found)}")
    return found[0]


# --- transcript -------------------------------------------------------------


def read_segments(path: Path) -> list[dict[str, Any]]:
    segments = load_json(path)
    require(isinstance(segments, list), f"{path} must hold a JSON array")
    return segments


def check_segments(segments: list[dict[str, Any]], duration_ms: int) -> None:
    require(len(segments) >= 2, "the long fixture must produce multiple segments")
    previous_end = 0
    for segment in segments:
        require(isinstance(segment, dict) and set(segment) == SEGMENT_KEYS,
                f"segment keys must be {sorted(SEGMENT_KEYS)}")
        start, end, text = segment["start_ms"], segment["end_ms"], segment["text"]
        require(is_int(start) and is_int(end) and 0 <= start < end <= duration_ms,
                f"segment range out of bounds: {start}..{end}")
        require(start >= previous_end, "segments must be chronological and nonoverlapping")
        require(isinstance(text, str) and text.strip() != "", "every segment needs text")
        require(JAPANESE_SCRIPT.search(text) is not None, f"segment is not Japanese: {text!r}")
        require(isinstance(segment["display_text"], str), "display_text must be a string")
        require(isinstance(segment["source"], dict), "source must be an object")
        require(isinstance(segment["segment_id"], str) and segment["segment_id"] != "",
                "segment_id must be a nonempty string")
        require(segment["clause_state"] == "classified",
                f"clause_state must be classified, got {segment['clause_state']!r}")
        slices = segment["clause_slices"]
        require(isinstance(slices, list) and slices, "clause_slices must be a nonempty array")
        for clause in slices:
            require(isinstance(clause, dict) and clause.get("priority") is not None
                    and clause.get("needs_retry") is False,
                    "every clause slice needs a priority and no retry")
        previous_end = end


def transcript_text(segments: list[dict[str, Any]]) -> str:
    return "\n".join(segment["text"] for segment in sorted(segments, key=lambda s: s["start_ms"]))


def evaluate_cer(
    evaluator: Path, reference: str, hypothesis: str, duration_ms: int, work: Path
) -> float:
    """CER through the product evaluator (same path as the TranscribeFile test)."""
    work.mkdir(parents=True, exist_ok=True)
    reference_path = work / "reference.txt"
    artifact_path = work / "artifact.json"
    report_path = work / "report.json"
    reference_path.write_text(reference, encoding="utf-8")
    artifact_path.write_text(
        json.dumps({
            "schema_version": 2,
            "segments": [{"start_ms": 0, "end_ms": duration_ms, "text": hypothesis}],
        }),
        encoding="utf-8",
    )
    run_command(
        [str(evaluator), str(reference_path), str(artifact_path), "--output", str(report_path)],
        os.environ.copy(), EVALUATOR_TIMEOUT_SECONDS, "ASR evaluator",
    )
    rate = load_json(report_path)["normalized"]["rate"]
    require(isinstance(rate, (int, float)) and not isinstance(rate, bool), "evaluator rate is not a number")
    return float(rate)


# --- speakers ---------------------------------------------------------------


def make_speaker_labels(segments: list[dict[str, Any]]) -> dict[str, str]:
    """Port of SpeakerDisplayMapper.makeLabels: ordered by first start, then id."""
    first_start: dict[str, int] = {}
    for segment in segments:
        for span in segment["speakers"]:
            if span["start_ms"] < span["end_ms"]:
                first_start[span["id"]] = min(first_start.get(span["id"], span["start_ms"]), span["start_ms"])
    ordered = sorted(first_start.items(), key=lambda item: (item[1], item[0]))
    return {
        speaker: f"Speaker {index + 1}" if index < INDIVIDUAL_SPEAKER_LIMIT else "OTHER"
        for index, (speaker, _) in enumerate(ordered)
    }


def turn_labels(segment: dict[str, Any], labels: dict[str, str]) -> list[str]:
    """Port of SpeakerDisplayMapper.turnLabels."""
    overlap: dict[str, int] = {}
    for span in segment["speakers"]:
        value = min(segment["end_ms"], span["end_ms"]) - max(segment["start_ms"], span["start_ms"])
        if value > 0:
            overlap[span["id"]] = overlap.get(span["id"], 0) + value
    total = sum(overlap.values())
    if total == 0:
        return ["UNKNOWN"]
    dominant = max(overlap, key=lambda speaker: overlap[speaker])
    if overlap[dominant] / total >= 0.8:
        return [labels.get(dominant, "UNKNOWN")]
    result: list[str] = []
    for span in sorted(segment["speakers"], key=lambda s: s["start_ms"]):
        if span["id"] in overlap:
            label = labels.get(span["id"], "UNKNOWN")
            if label not in result:
                result.append(label)
    return result


def check_speakers(segments: list[dict[str, Any]], duration_ms: int) -> None:
    for segment in segments:
        spans = segment["speakers"]
        require(isinstance(spans, list), "speakers must be an array")
        for span in spans:
            require(isinstance(span, dict) and isinstance(span.get("id"), str) and span["id"] != "",
                    "speaker span needs a nonempty raw id")
            require(is_int(span.get("start_ms")) and is_int(span.get("end_ms"))
                    and 0 <= span["start_ms"] < span["end_ms"] <= duration_ms,
                    f"speaker span out of bounds: {span}")
    labels = make_speaker_labels(segments)
    for segment in segments:
        produced = turn_labels(segment, labels)
        require(produced and all(label in VALID_LABELS for label in produced),
                f"invalid speaker labels {produced} for {segment['segment_id']}")


# --- session ----------------------------------------------------------------


def read_events(session: Path) -> list[dict[str, Any]]:
    path = session / "events.jsonl"
    require(path.is_file(), f"missing file: {path}")
    data = path.read_bytes()
    require(data.endswith(b"\n"), "events.jsonl must end with a newline (complete log)")
    events = []
    previous = 0
    for number, line in enumerate(data.decode("utf-8").splitlines(), start=1):
        try:
            event = json.loads(line)
        except ValueError as error:
            raise AcceptanceFailure(f"events.jsonl line {number} is not JSON: {error}") from error
        require(isinstance(event, dict) and event.get("schema_version") == EVENT_SCHEMA_VERSION,
                f"events.jsonl line {number} has no schema_version {EVENT_SCHEMA_VERSION}")
        require(is_int(event.get("event_seq")) and event["event_seq"] > previous,
                f"events.jsonl line {number}: event_seq must increase")
        previous = event["event_seq"]
        events.append(event)
    require(events, "events.jsonl is empty")
    return events


def check_session_files(
    session: Path, original_audio: Path, session_id: str, expected_frames: int
) -> None:
    manifest = load_json(session / "session.json")
    require(str(uuid.UUID(manifest["session_id"])) == session_id, "session.json session_id differs")
    require(manifest["source_kind"] == "imported", "session.json source_kind must be imported")
    require(manifest["original_filename"] == original_audio.name, "session.json original_filename differs")

    audio = session / "audio"
    storage = load_json(audio / "storage.json")
    require(storage.get("state") == "importedOriginal", "audio/storage.json state must be importedOriginal")
    timeline = storage.get("timeline")
    require(isinstance(timeline, dict) and timeline.get("committedFrames") == expected_frames,
            "audio/storage.json timeline must hold the imported frame count")

    originals = [p for p in audio.iterdir()
                 if p.name == "original" or p.name.startswith("original.")]
    require(len(originals) == 1, f"audio/ must hold exactly one original, found {len(originals)}")
    require(originals[0].read_bytes() == original_audio.read_bytes(),
            "stored original is not byte-identical to the input")
    require(not list(audio.rglob("*.caf")), "processing CAF files remain under audio/")
    require(not (audio / "derived").exists() or not any((audio / "derived").iterdir()),
            "audio/derived is not empty")
    require(not (audio / "recording.flac").exists() and not (audio / ".recording.flac.partial").exists(),
            "an import must not hold recording.flac")
    require((session / "processing_metadata.json").is_file(), "missing processing_metadata.json")


def check_runs(
    events: list[dict[str, Any]], metadata: dict[str, Any], expected_model: str, threads: int
) -> dict[str, str]:
    """Check metadata and run events; returns the active run ids by stage key."""
    attempt = metadata.get("finalization_attempt")
    require(isinstance(attempt, dict) and attempt.get("state") == "complete",
            "finalization attempt is not complete")
    require(metadata.get("pending_clause_boundary_segments") == []
            and metadata.get("pending_content_priority_clauses") == [],
            "decision targets are still pending")
    active = metadata.get("active_runs")
    require(isinstance(active, dict), "no active runs are published")
    run_ids: dict[str, str] = {}
    for key, (stage, expected_engine) in STAGES.items():
        run_id = active.get(key)
        require(isinstance(run_id, str) and run_id != "", f"active run missing for {key}")
        started = [e for e in events if e["event_type"] == "processing.run.started"
                   and e.get("processing_run_id") == run_id]
        completed = [e for e in events if e["event_type"] == "processing.run.completed"
                     and e.get("processing_run_id") == run_id]
        require(len(started) == 1 and len(completed) == 1, f"{key} run {run_id} needs one start and one completion")
        require(started[0]["payload"]["stage"] == stage and completed[0]["payload"]["stage"] == stage,
                f"{key} run events carry the wrong stage")
        require(started[0]["event_seq"] < completed[0]["event_seq"], f"{key} run completed before it started")
        require(completed[0]["payload"]["succeeded"] is True and completed[0]["payload"]["failed_count"] == 0,
                f"{key} run did not succeed")
        provenance = started[0]["payload"]["provenance"]
        engine = provenance["engine"]
        if expected_engine is not None:
            require(engine == expected_engine, f"{key} engine must be {expected_engine}, got {engine}")
        else:
            lowered = engine.lower()
            require("onnx" in lowered and "coreml" not in lowered and engine != "unavailable",
                    f"{key} decision engine must be an ONNX engine, got {engine}")
            require(isinstance(provenance.get("model"), str) and provenance["model"] != "",
                    f"{key} decision run needs a model identity")
        if key == "asr":
            require(provenance["model"] == expected_model, f"ASR model must be {expected_model}")
            require(provenance["configuration"].get("intra_op_threads") == str(threads),
                    f"ASR intra_op_threads must be {threads}")
        run_ids[key] = run_id
    for event_type, key in (("clause_boundaries.assessed", "clause_boundary"),
                            ("content_priority.assigned", "content_priority")):
        require(any(e["event_type"] == event_type and e.get("processing_run_id") == run_ids[key] for e in events),
                f"no {event_type} event in the active {key} run")
    return run_ids


def check_export_matches_events(
    segments: list[dict[str, Any]], events: list[dict[str, Any]], asr_run_id: str
) -> None:
    recognized = {
        e["segment_id"]: e["payload"]["text"]
        for e in events
        if e["event_type"] == "asr.completed" and e.get("processing_run_id") == asr_run_id
        and e["payload"].get("outcome") == "recognized"
    }
    exported = {segment["segment_id"]: segment["text"] for segment in segments}
    require(exported == recognized, "exported segments differ from the active ASR events")


def check_session(
    session: Path, original_audio: Path, session_id: str, expected_frames: int,
    segments: list[dict[str, Any]], expected_model: str, threads: int,
) -> None:
    check_session_files(session, original_audio, session_id, expected_frames)
    events = read_events(session)
    metadata = load_json(session / "processing_metadata.json")
    run_ids = check_runs(events, metadata, expected_model, threads)
    check_export_matches_events(segments, events, run_ids["asr"])


# --- scenario ---------------------------------------------------------------


def run_acceptance(
    executable: Path, evaluator: Path, fixture: Path, work: Path, environment: dict[str, str]
) -> dict[str, Any]:
    models = require_model_environment(environment)
    require_executable(executable, "executable")
    require_executable(evaluator, "evaluator")
    reference, fixture_sha256, samples = load_reference()
    duration_ms = inspect_fixture(fixture, fixture_sha256, samples)
    expected_model = expected_asr_model(models[QWEN3_SIZE_VARIABLE])

    sessions_root = work / "sessions"
    sessions_root.mkdir(parents=True)
    import_output = work / "import-segments.json"
    resume_output = work / "resume-segments.json"
    root_argument = ["--sessions-root", str(sessions_root)]
    threads_argument = ["--threads", str(THREADS)]

    imported = run_command(
        [str(executable), *root_argument, "--keep-session", "--with-decisions", *threads_argument,
         str(fixture), str(import_output)],
        environment, IMPORT_TIMEOUT_SECONDS, "import",
    )
    session_id = parse_session_id(imported.stdout)
    session = find_session_directory(sessions_root, session_id)
    segments = read_segments(import_output)
    check_segments(segments, duration_ms)
    check_speakers(segments, duration_ms)
    cer = evaluate_cer(evaluator, reference, transcript_text(segments), duration_ms, work / "cer")
    require(cer <= MAX_NORMALIZED_CER, f"normalized CER {cer:.4f} exceeds {MAX_NORMALIZED_CER}")
    check_session(session, fixture, session_id, samples, segments, expected_model, THREADS)
    events_before = (session / "events.jsonl").read_bytes()

    bare_environment = {k: v for k, v in environment.items() if k not in MODEL_VARIABLES}
    inspected = run_command(
        [str(executable), "--inspect-session", session_id, *root_argument],
        bare_environment, INSPECT_TIMEOUT_SECONDS, "inspect",
    )
    try:
        inspection = json.loads(inspected.stdout)
    except ValueError as error:
        raise AcceptanceFailure(f"inspect output is not JSON: {inspected.stdout!r}") from error
    require(isinstance(inspection, dict) and set(inspection) == {"session_id", "action", "maintenance"},
            f"inspect output keys differ: {inspection}")
    require(str(uuid.UUID(inspection["session_id"])) == session_id, "inspect reports another session")
    require(inspection["action"] == "none" and inspection["maintenance"] is None,
            f"inspect must report action none without maintenance, got {inspection}")

    run_command(
        [str(executable), "--resume-session", session_id, *root_argument, "--with-decisions",
         *threads_argument, str(resume_output)],
        environment, RESUME_TIMEOUT_SECONDS, "resume",
    )
    require(read_segments(resume_output) == segments, "resume output differs from import output")
    require((session / "events.jsonl").read_bytes() == events_before,
            "resume of a completed session appended events")
    check_session(session, fixture, session_id, samples, segments, expected_model, THREADS)
    return {"session_id": session_id, "segments": len(segments), "normalized_cer": cer}


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", type=Path, required=True,
                        help="release MacAmbientJevProcessRecording (absolute path)")
    parser.add_argument("--evaluator", type=Path, required=True,
                        help="release MacAmbientJevEvaluateASR (absolute path)")
    parser.add_argument("--fixture", type=Path, required=True, help="qwen3_asr_voicevox_long.wav")
    arguments = parser.parse_args(argv)
    work = Path(tempfile.mkdtemp(prefix="process-recording-acceptance-"))
    try:
        summary = run_acceptance(arguments.executable, arguments.evaluator, arguments.fixture,
                                 work, os.environ.copy())
    except AcceptanceFailure as error:
        print(f"acceptance failed: {error}\nwork directory kept: {work}", file=sys.stderr)
        return 1
    shutil.rmtree(work)
    print(f"acceptance passed: {json.dumps(summary, ensure_ascii=False)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
