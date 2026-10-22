from __future__ import annotations

import copy
import os
import stat
import sys
from pathlib import Path

import pytest

import process_recording_acceptance as acceptance
from process_recording_acceptance import AcceptanceFailure
import fake_process_recording as fake

TESTS_DIRECTORY = Path(__file__).resolve().parent
FIXTURE = (
    acceptance.REPOSITORY_ROOT
    / "app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/Resources/qwen3_asr_voicevox_long.wav"
)

posix_only = pytest.mark.skipif(sys.platform == "win32", reason="fake executables are POSIX scripts")


def make_script(path: Path, function: str) -> Path:
    path.write_text(
        f"#!{sys.executable}\n"
        "import sys\n"
        f"sys.path.insert(0, {str(TESTS_DIRECTORY)!r})\n"
        f"sys.path.insert(0, {str(TESTS_DIRECTORY.parent)!r})\n"
        "import fake_process_recording as fake\n"
        f"raise SystemExit(fake.{function}(sys.argv[1:]))\n",
        encoding="utf-8",
    )
    path.chmod(path.stat().st_mode | stat.S_IXUSR)
    return path


@pytest.fixture
def environment(tmp_path: Path) -> dict[str, str]:
    silero = tmp_path / "silero.onnx"
    silero.write_bytes(b"x")
    directories = {}
    for name in ("qwen", "diarization", "tagger"):
        directories[name] = tmp_path / name
        directories[name].mkdir()
    return {
        **os.environ,
        acceptance.SILERO_VARIABLE: str(silero),
        acceptance.QWEN3_DIRECTORY_VARIABLE: str(directories["qwen"]),
        acceptance.QWEN3_SIZE_VARIABLE: "0.6b",
        acceptance.DIARIZATION_VARIABLE: str(directories["diarization"]),
        acceptance.CLAUSE_TAGGER_VARIABLE: str(directories["tagger"]),
    }


def run_with_mode(tmp_path: Path, environment: dict[str, str], mode: str) -> dict:
    executable = make_script(tmp_path / "process-recording", "cli")
    evaluator = make_script(tmp_path / "evaluate-asr", "evaluator")
    work = tmp_path / f"work-{mode}"
    work.mkdir()
    return acceptance.run_acceptance(
        executable, evaluator, FIXTURE, work, {**environment, fake.MODE_VARIABLE: mode}
    )


@posix_only
def test_good_run_passes(tmp_path, environment):
    summary = run_with_mode(tmp_path, environment, "good")
    assert summary["segments"] == 2
    assert summary["normalized_cer"] == 0


@posix_only
@pytest.mark.parametrize(
    ("mode", "message"),
    [
        ("wrong_transcript", "CER"),
        ("missing_stage", "active run missing for diarization"),
        ("bad_speaker", "nonempty raw id"),
        ("missing_file", "storage.json"),
        ("leftover_caf", "CAF"),
        ("coreml_decision", "ONNX engine"),
        ("resume_differs", "resume output differs"),
    ],
)
def test_broken_run_fails(tmp_path, environment, mode, message):
    with pytest.raises(AcceptanceFailure, match=message):
        run_with_mode(tmp_path, environment, mode)


@pytest.mark.parametrize("name", acceptance.MODEL_VARIABLES)
def test_missing_model_variable_fails(environment, name):
    del environment[name]
    with pytest.raises(AcceptanceFailure, match=name):
        acceptance.require_model_environment(environment)


def test_empty_and_relative_model_variables_fail(environment):
    with pytest.raises(AcceptanceFailure, match="MODEL_SIZE"):
        acceptance.require_model_environment({**environment, acceptance.QWEN3_SIZE_VARIABLE: "2b"})
    with pytest.raises(AcceptanceFailure, match="absolute"):
        acceptance.require_model_environment({**environment, acceptance.SILERO_VARIABLE: "silero.onnx"})
    with pytest.raises(AcceptanceFailure, match="required"):
        acceptance.require_model_environment({**environment, acceptance.SILERO_VARIABLE: ""})


def test_missing_executable_fails(tmp_path):
    with pytest.raises(AcceptanceFailure, match="does not exist"):
        acceptance.require_executable(tmp_path / "missing", "executable")
    with pytest.raises(AcceptanceFailure, match="absolute"):
        acceptance.require_executable(Path("relative"), "executable")


def test_fixture_matches_documented_hash():
    reference, sha256, samples = acceptance.load_reference()
    assert reference.startswith("通信相手を認証したあと")
    assert acceptance.inspect_fixture(FIXTURE, sha256, samples) == 18_464
    with pytest.raises(AcceptanceFailure, match="SHA-256"):
        acceptance.inspect_fixture(FIXTURE, "0" * 64, samples)


def test_session_id_line_must_appear_once():
    value = "6F9619FF-8B86-D011-B42D-00C04FC964FF"
    assert acceptance.parse_session_id(f"x\nsession_id: {value}\ny") == value.lower()
    with pytest.raises(AcceptanceFailure, match="exactly one"):
        acceptance.parse_session_id("no id")
    with pytest.raises(AcceptanceFailure, match="exactly one"):
        acceptance.parse_session_id(f"session_id: {value}\nsession_id: {value}")


def segments_fixture() -> list[dict]:
    return fake.exported(fake.good_segments(fake.reference_text()), "good")


def test_segment_checks():
    segments = segments_fixture()
    acceptance.check_segments(segments, fake.DURATION_MS)
    for mutate, message in [
        (lambda s: s.pop(), "multiple segments"),
        (lambda s: s[1].update(start_ms=100), "chronological"),
        (lambda s: s[1].update(end_ms=99_999), "out of bounds"),
        (lambda s: s[0].update(text="abc"), "not Japanese"),
        (lambda s: s[0].update(clause_state="priority_pending"), "classified"),
        (lambda s: s[0].update(clause_slices=[{"priority": None, "needs_retry": False}]), "priority"),
        (lambda s: s[0].pop("display_text"), "keys"),
    ]:
        broken = copy.deepcopy(segments)
        mutate(broken)
        with pytest.raises(AcceptanceFailure, match=message):
            acceptance.check_segments(broken, fake.DURATION_MS)


def span(speaker: str, start: int, end: int) -> dict:
    return {"id": speaker, "start_ms": start, "end_ms": end}


def segment(start: int, end: int, spans: list[dict]) -> dict:
    return {"segment_id": f"s{start}", "start_ms": start, "end_ms": end, "speakers": spans}


def test_speaker_labels_follow_the_product_mapper():
    eight = [segment(i * 100, i * 100 + 100, [span(f"id{i}", i * 100, i * 100 + 100)]) for i in range(8)]
    labels = acceptance.make_speaker_labels(eight)
    assert [labels[f"id{i}"] for i in range(8)] == [f"Speaker {n}" for n in range(1, 8)] + ["OTHER"]
    acceptance.check_speakers(eight, 800)
    assert acceptance.turn_labels(segment(0, 100, []), labels) == ["UNKNOWN"]
    mixed = segment(0, 100, [span("id0", 0, 60), span("id1", 60, 100)])
    assert acceptance.turn_labels(mixed, labels) == ["Speaker 1", "Speaker 2"]
    dominant = segment(0, 100, [span("id0", 0, 85), span("id1", 85, 100)])
    assert acceptance.turn_labels(dominant, labels) == ["Speaker 1"]


def test_speaker_span_must_stay_in_range():
    with pytest.raises(AcceptanceFailure, match="out of bounds"):
        acceptance.check_speakers([segment(0, 100, [span("a", 0, 900)])], 800)
    with pytest.raises(AcceptanceFailure, match="raw id"):
        acceptance.check_speakers([segment(0, 100, [span("", 0, 100)])], 800)
