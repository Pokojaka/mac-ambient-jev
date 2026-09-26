from __future__ import annotations

import json
import math
import pathlib
import wave

import pytest

from common.artifact import (
    build_asr_artifact,
    validate_asr_artifact,
    write_json_atomic,
)
from asr.qwen3_asr import (
    DEFAULT_MODEL,
    DEFAULT_MODEL_REVISION,
    resolve_model_revision,
    run_transcription,
)


def make_wav(
    path: pathlib.Path,
    frames: int = 1600,
    sample_rate: int = 16000,
) -> None:
    with wave.open(str(path), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(sample_rate)
        wav.writeframes(b"\x00\x00" * frames)


def test_build_asr_artifact_records_runtime_and_model_metadata():
    artifact = build_asr_artifact(
        model="Qwen/Qwen3-ASR-1.7B",
        revision="abc123",
        backend="transformers",
        device="cuda:0",
        text="公開鍵暗号",
        language="Japanese",
        audio_seconds=10.0,
        inference_seconds=2.0,
    )
    assert artifact["schema_version"] == 1
    assert artifact["engine"]["model"] == "Qwen/Qwen3-ASR-1.7B"
    assert artifact["engine"]["revision"] == "abc123"
    assert artifact["runtime"]["rtf"] == pytest.approx(0.2)
    assert artifact["segments"][0]["text"] == "公開鍵暗号"


def test_validate_asr_artifact_rejects_non_finite_runtime():
    artifact = build_asr_artifact(
        model="m",
        revision=None,
        backend="transformers",
        device="cpu",
        text="x",
        language="Japanese",
        audio_seconds=1.0,
        inference_seconds=1.0,
    )
    artifact["runtime"]["rtf"] = math.inf

    with pytest.raises(ValueError, match="finite"):
        validate_asr_artifact(artifact)


def test_write_json_atomic_writes_valid_json(
    tmp_path: pathlib.Path,
):
    output = tmp_path / "result.json"
    payload = {"schema_version": 1, "ok": True}
    write_json_atomic(output, payload)
    assert json.loads(output.read_text(encoding="utf-8")) == payload


def test_run_transcription_uses_injected_backend_and_writes_artifact(
    tmp_path: pathlib.Path,
):
    audio = tmp_path / "sample.wav"
    output = tmp_path / "result.json"
    make_wav(audio)

    def fake_transcribe(path: pathlib.Path):
        assert path == audio
        return "テストです", "Japanese"

    result = run_transcription(
        audio_path=audio,
        output_path=output,
        model="Qwen/Qwen3-ASR-1.7B",
        revision=None,
        device="cpu",
        transcribe=fake_transcribe,
    )

    assert result["segments"][0]["text"] == "テストです"
    assert output.exists()
    saved = json.loads(output.read_text(encoding="utf-8"))
    assert saved["segments"][0]["text"] == "テストです"


def test_run_transcription_removes_stale_output_when_backend_fails(
    tmp_path: pathlib.Path,
):
    audio = tmp_path / "sample.wav"
    output = tmp_path / "result.json"
    make_wav(audio)
    output.write_text('{"stale":true}', encoding="utf-8")

    def fail(_: pathlib.Path):
        raise RuntimeError("boom")

    with pytest.raises(RuntimeError, match="boom"):
        run_transcription(
            audio_path=audio,
            output_path=output,
            model="Qwen/Qwen3-ASR-1.7B",
            revision=None,
            device="cpu",
            transcribe=fail,
        )

    assert not output.exists()


def test_default_qwen_model_revision_is_pinned():
    expected = (
        "7278e1e70fe206f11671096ffdd38061171dd6e5"
    )
    assert DEFAULT_MODEL_REVISION == expected
    assert resolve_model_revision(
        DEFAULT_MODEL,
        None,
    ) == expected


def test_custom_qwen_model_requires_explicit_revision():
    with pytest.raises(ValueError, match="revision"):
        resolve_model_revision(
            "example/custom-asr",
            None,
        )
    assert resolve_model_revision(
        "example/custom-asr",
        "abc123",
    ) == "abc123"


def test_asr_environment_pins_qwen_asr_release():
    import tomllib

    pyproject = (
        pathlib.Path(__file__).resolve().parents[1]
        / "asr"
        / "pyproject.toml"
    )
    data = tomllib.loads(
        pyproject.read_text(encoding="utf-8")
    )
    assert (
        "qwen-asr==0.0.6"
        in data["project"]["dependencies"]
    )
