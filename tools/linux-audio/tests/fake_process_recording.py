"""Fake MacAmbientJevProcessRecording and MacAmbientJevEvaluateASR for driver self-tests.

The behaviour is chosen by FAKE_PROCESS_RECORDING_MODE; "good" satisfies every check.
"""

from __future__ import annotations

import json
import os
import shutil
import sys
import uuid
from pathlib import Path

import process_recording_acceptance as acceptance

MODE_VARIABLE = "FAKE_PROCESS_RECORDING_MODE"
DURATION_MS = 18_464
FRAMES = 295_424
MODEL = "andrewleech/qwen3-asr-0.6b-onnx@4fc24a1402e74db89c4d2ef256875e71680128c4"
WRONG_TEXT = "あいうえおかきくけこさしすせそたちつてと" * 3


def reference_text() -> str:
    return acceptance.load_reference()[0]


def good_segments(text: str) -> list[dict]:
    first, second = text[:50], text[50:]
    return [
        {"id": "seg_1", "start_ms": 500, "end_ms": 9_000, "text": first},
        {"id": "seg_2", "start_ms": 9_500, "end_ms": 18_000, "text": second},
    ]


def provenance(engine: str, model: str, configuration: dict | None = None) -> dict:
    return {"engine": engine, "model": model, "version": "1", "configuration": configuration or {}}


def build_session(session: Path, audio: Path, session_id: str, mode: str, segments: list[dict]) -> None:
    (session / "audio").mkdir(parents=True)
    (session / "session.json").write_text(json.dumps({
        "session_id": session_id, "created_at": "2026-10-22T00:00:00Z",
        "source_kind": "imported", "original_filename": audio.name,
    }), encoding="utf-8")
    shutil.copyfile(audio, session / "audio" / "original.wav")
    (session / "audio" / "storage.json").write_text(json.dumps({
        "state": "importedOriginal",
        "timeline": {"committedFrames": FRAMES, "sampleRate": 16000, "channelCount": 1, "gapEvents": []},
    }), encoding="utf-8")
    runs = {
        "segmentation": ("segmentation", provenance("onnxruntime-silero-vad", "silero_vad.onnx")),
        "asr": ("asr", provenance("onnxruntime-qwen3-asr", MODEL, {"intra_op_threads": "2"})),
        "diarization": ("diarization", provenance("onnxruntime-community1-diarizer", "community-1")),
        "clause_boundary": ("clauseBoundary", provenance(
            "coreml-clause-tagger" if mode == "coreml_decision" else "onnxruntime-clause-tagger", "tagger")),
        "content_priority": ("contentPriority", provenance("onnxruntime-clause-tagger", "tagger")),
    }
    events: list[dict] = []

    def add(event_type: str, run_id: str | None, payload: dict, segment_id: str | None = None) -> None:
        events.append({
            "event_seq": len(events) + 1, "event_id": str(uuid.uuid4()), "event_type": event_type,
            "schema_version": 3, "session_id": session_id, "processing_run_id": run_id,
            "segment_id": segment_id, "payload": payload,
        })

    for key, (stage, prov) in runs.items():
        add("processing.run.started", f"{key}_run", {"stage": stage, "provenance": prov})
        if key == "asr":
            for segment in segments:
                add("asr.completed", "asr_run", {"text": segment["text"], "engine": prov["engine"],
                                                 "model": prov["model"], "outcome": "recognized"}, segment["id"])
        if key == "clause_boundary":
            add("clause_boundaries.assessed", "clause_boundary_run", {})
        if key == "content_priority":
            add("content_priority.assigned", "content_priority_run", {})
        add("processing.run.completed", f"{key}_run",
            {"stage": stage, "succeeded": True, "completed_count": 1, "failed_count": 0})
    (session / "events.jsonl").write_text(
        "".join(json.dumps(event) + "\n" for event in events), encoding="utf-8")

    active = {key: f"{key}_run" for key in runs}
    if mode == "missing_stage":
        del active["diarization"]
    (session / "processing_metadata.json").write_text(json.dumps({
        "schema_version": 3, "finalization_attempt": {"attempt_id": "a", "state": "complete"},
        "active_runs": active, "pending_clause_boundary_segments": [],
        "pending_content_priority_clauses": [],
    }), encoding="utf-8")
    if mode == "missing_file":
        (session / "audio" / "storage.json").unlink()
    if mode == "leftover_caf":
        (session / "audio" / "processing").mkdir()
        (session / "audio" / "processing" / "chunk.caf").write_bytes(b"caf")


def exported(segments: list[dict], mode: str) -> list[dict]:
    result = []
    for segment in segments:
        speaker_id = "" if mode == "bad_speaker" else "speaker_0"
        result.append({
            "segment_id": segment["id"], "source": {"asr_run_id": "asr_run"},
            "start_ms": segment["start_ms"], "end_ms": segment["end_ms"],
            "text": segment["text"], "display_text": segment["text"],
            "speakers": [{"id": speaker_id, "start_ms": segment["start_ms"], "end_ms": segment["end_ms"]}],
            "clause_state": "classified",
            "clause_slices": [{"priority": "primary", "needs_retry": False}],
        })
    return result


def write_output(path: Path, value: list[dict]) -> None:
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False), encoding="utf-8")


def cli(arguments: list[str]) -> int:
    mode = os.environ[MODE_VARIABLE]
    if "--inspect-session" in arguments:
        if any(name in os.environ for name in acceptance.MODEL_VARIABLES):
            print("model variables must not reach inspect", file=sys.stderr)
            return 3
        value = arguments[arguments.index("--inspect-session") + 1]
        print(json.dumps({"session_id": value.upper(), "action": "none", "maintenance": None}))
        return 0
    root = Path(arguments[arguments.index("--sessions-root") + 1])
    text = WRONG_TEXT if mode == "wrong_transcript" else reference_text()
    segments = good_segments(text)
    if "--resume-session" in arguments:
        if mode == "resume_differs":
            segments = good_segments(WRONG_TEXT)
        write_output(Path(arguments[-1]), exported(segments, mode))
        return 0
    audio, output = Path(arguments[-2]), Path(arguments[-1])
    session_id = str(uuid.uuid4()).upper()
    build_session(root / f"session-{session_id[:8]}", audio, session_id, mode, segments)
    print(f"session_id: {session_id}")
    write_output(output, exported(segments, mode))
    return 0


def levenshtein(a: str, b: str) -> int:
    previous = list(range(len(b) + 1))
    for i, ca in enumerate(a, start=1):
        current = [i]
        for j, cb in enumerate(b, start=1):
            current.append(min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (ca != cb)))
        previous = current
    return previous[-1]


def evaluator(arguments: list[str]) -> int:
    def strip(value: str) -> str:
        return "".join(c for c in value if c not in "、。\n ")

    reference = strip(Path(arguments[0]).read_text(encoding="utf-8"))
    hypothesis = strip(json.loads(Path(arguments[1]).read_text(encoding="utf-8"))["segments"][0]["text"])
    rate = levenshtein(reference, hypothesis) / len(reference)
    Path(arguments[3]).write_text(json.dumps({"normalized": {"rate": rate}}), encoding="utf-8")
    return 0
