#!/usr/bin/env python3
import json
import shutil
import pathlib
import subprocess
import sys
import tempfile


binary = pathlib.Path(sys.argv[1]).resolve()
session_id = "31AC3491-986E-4F0A-8697-E9181B0910D4"

with tempfile.TemporaryDirectory(prefix="mac-ambient-jev-cli-") as temporary:
    root = pathlib.Path(temporary)
    sessions = root / "sessions"
    sessions.mkdir()
    output = root / "segments.json"
    metrics = root / "metrics.json"
    thermal = root / "thermal.jsonl"
    memory = root / "memory.jsonl"
    invalid = [
        ["--resume-session", session_id, "--sessions-root", str(sessions), "audio.wav", str(output)],
        ["--inspect-session", session_id, "--sessions-root", str(sessions), "audio.wav"],
        ["--inspect-session", session_id, "--sessions-root", str(sessions), "--low-heat"],
        ["--resume-session", session_id, "--resume-session", session_id, "--sessions-root", str(sessions), str(output)],
        ["--resume-session", session_id, "--sessions-root", str(sessions), "--keep-session", str(output)],
        ["--resume-session", "--sessions-root", str(sessions), str(output)],
        ["--sessions-root", str(sessions), "--unexpected", "audio.wav", str(output)],
        ["--sessions-root", str(sessions), "--low-heat", "--low-heat", "audio.wav", str(output)],
        ["--sessions-root", str(sessions), "--run-id", "incomplete", "--metrics-output", str(metrics), "audio.wav", str(output)],
        ["--run-id", "inspect", "--metrics-output", str(metrics),
         "--thermal-output", str(thermal), "--memory-output", str(memory),
         "--inspect-session", session_id, "--sessions-root", str(sessions)],
        ["--inspect-session", session_id],
        ["--inspect-session", session_id, "--sessions-root", str(pathlib.Path.home() / "Library/Application Support/mac-ambient-jev")],
    ]
    for arguments in invalid:
        result = subprocess.run([str(binary), *arguments], capture_output=True)
        assert result.returncode != 0, arguments
        assert not output.exists(), arguments
        assert not metrics.exists() and not thermal.exists() and not memory.exists(), arguments
        assert list(sessions.iterdir()) == [], arguments

    def inspect(identity):
        return subprocess.run(
            [str(binary), "--inspect-session", identity, "--sessions-root", str(sessions)],
            capture_output=True, text=True,
        )

    missing = inspect(session_id)
    assert missing.returncode != 0 and not missing.stdout.strip(), missing
    session = sessions / "2024-02-29_23-59-59_録音_31ac3491"
    session.mkdir()
    manifest = {
        "session_id": session_id, "created_at": "2024-03-01T00:00:00Z",
        "source_kind": "recording", "capture_source": "systemAudio",
    }
    (session / "session.json").write_text(json.dumps(manifest))
    events = []
    active_runs = {"segmentation": "fixture-seg", "diarization": "fixture-diar", "asr": "fixture-asr"}
    for stage, run_id in active_runs.items():
        for event_type, payload in [
            ("processing.run.started", {
                "stage": stage,
                "provenance": {"engine": "fixture", "model": None, "version": "test", "configuration": {}},
            }),
            ("processing.run.completed", {
                "stage": stage, "succeeded": True, "completed_count": 0, "failed_count": 0,
            }),
        ]:
            events.append({
                "event_seq": len(events) + 1,
                "event_id": f"75AC3491-986E-4F0A-8697-E9181B0910D{len(events)}",
                "event_type": event_type, "schema_version": 3, "session_id": session_id,
                "processing_run_id": run_id, "created_at": "2024-03-01T00:00:00Z", "payload": payload,
            })
    event_path = session / "events.jsonl"
    event_bytes = "".join(json.dumps(event) + "\n" for event in events)
    event_path.write_text(event_bytes)
    metadata = {
        "schema_version": 3,
        "finalization_attempt": {"attempt_id": "fixture-attempt", "state": "complete", "failure_reason": None},
        "active_runs": active_runs,
        "pending_clause_boundary_segments": [], "pending_content_priority_clauses": [],
    }
    metadata_path = session / "processing_metadata.json"
    metadata_path.write_text(json.dumps(metadata))
    (session / "audio").mkdir()
    (session / "audio" / "storage.json").write_text(json.dumps({"state": "recordingPCM"}))
    before = {str(p.relative_to(session)): p.read_bytes() for p in session.rglob("*") if p.is_file()}
    valid = inspect(session_id.lower())
    assert valid.returncode == 0, valid.stderr
    assert json.loads(valid.stdout) == {"session_id": session_id, "action": "none", "maintenance": None}, valid.stdout

    schema_cases = [("unsupported", 2), ("invalid type", "3"), ("boolean", True), ("missing", None)]
    for label, version in schema_cases:
        invalid_metadata = dict(metadata)
        if label == "missing":
            invalid_metadata.pop("schema_version")
        else:
            invalid_metadata["schema_version"] = version
        metadata_path.write_text(json.dumps(invalid_metadata))
        invalid_bytes = metadata_path.read_bytes()
        rejected = inspect(session_id)
        assert rejected.returncode != 0 and not rejected.stdout.strip(), (label, rejected)
        assert metadata_path.read_bytes() == invalid_bytes
        assert event_path.read_text() == event_bytes
        metadata_path.write_text(json.dumps(metadata))
    for label, version in schema_cases:
        invalid_event = dict(events[-1])
        if label == "missing":
            invalid_event.pop("schema_version")
        else:
            invalid_event["schema_version"] = version
        invalid_bytes = "".join(json.dumps(event) + "\n" for event in events[:-1]) + json.dumps(invalid_event) + "\n"
        event_path.write_text(invalid_bytes)
        rejected = inspect(session_id)
        assert rejected.returncode != 0 and not rejected.stdout.strip(), (label, rejected)
        assert event_path.read_text() == invalid_bytes
        assert metadata_path.read_bytes() == before["processing_metadata.json"]
        event_path.write_text(event_bytes)
    assert {str(p.relative_to(session)): p.read_bytes() for p in session.rglob("*") if p.is_file()} == before
    # Another full ID with the same prefix must not become a match.
    collision = sessions / "2024-03-01_00-00-00_録音_31ac3491"
    collision.mkdir()
    collision_manifest = dict(manifest, session_id="31AC3491-0000-4000-8000-000000000000")
    (collision / "session.json").write_text(json.dumps(collision_manifest))
    assert inspect(session_id).returncode == 0
    shutil.rmtree(collision)

    alias = root / "session-alias"
    alias.symlink_to(session, target_is_directory=True)
    for destination in [
        session / "events.jsonl", session / "nested" / "segments.json",
        alias / "session.json", sessions / session.name.upper() / "segments.json",
    ]:
        result = subprocess.run(
            [str(binary), "--resume-session", session_id, "--sessions-root", str(sessions), str(destination)],
            capture_output=True, text=True,
        )
        assert result.returncode != 0 and not result.stdout.strip(), result
        assert {str(p.relative_to(session)): p.read_bytes() for p in session.rglob("*") if p.is_file()} == before
    alias.unlink()

    duplicate = sessions / "2024-03-01_00-00-01_録音_31ac3491"
    shutil.copytree(session, duplicate)
    ambiguous = inspect(session_id)
    assert ambiguous.returncode != 0 and not ambiguous.stdout.strip(), ambiguous
    shutil.rmtree(duplicate)
    for name in [
        "malformed", "2024-02-30_23-59-59_録音_31ac3491",
        "2024-02-29_23-59-59_録音_deadbeef", "2024-02-29_23-59-59_wrong_31ac3491",
    ]:
        malformed = sessions / name
        session.rename(malformed)
        rejected = inspect(session_id)
        assert rejected.returncode != 0 and not rejected.stdout.strip(), rejected
        malformed.rename(session)
    assert {str(p.relative_to(session)): p.read_bytes() for p in session.rglob("*") if p.is_file()} == before
    assert not output.exists() and not metrics.exists() and not thermal.exists() and not memory.exists()

print(f"CLI rejected {len(invalid)} invalid input forms without writing files")
print("CLI inspected a named session and rejected missing, duplicate, malformed identities and contained resume outputs without model work")
