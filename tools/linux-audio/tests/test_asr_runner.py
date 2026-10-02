from __future__ import annotations

import copy
import json
import math
import pathlib
import wave

import pytest

from asr.qwen3_asr import run_transcription
from common.artifact import (
    build_asr_artifact,
    build_engine,
    build_runtime,
    validate_asr_artifact,
)
from common.runtime_metrics import RuntimeMeasurement


PACKAGES = {"qwen-asr": "0.0.6", "torch": "2.10.0", "transformers": "4.57.6"}


def make_wav(path: pathlib.Path, frames: int = 16_000) -> None:
    with wave.open(str(path), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(16_000)
        wav.writeframes(b"\x00\x00" * frames)


def make_artifact(device: str = "cpu") -> dict:
    cuda = device != "cpu"
    return build_asr_artifact(
        engine=build_engine(
            name="qwen3-asr",
            model="Qwen/Qwen3-ASR-1.7B",
            revision="abc123",
            backend="transformers",
            device=device,
            package_versions=PACKAGES,
            inference_config={"dtype": "bfloat16", "language": "Japanese"},
        ),
        runtime=build_runtime(
            device=device,
            audio_seconds=10.0,
            measurement=RuntimeMeasurement(
                model_load_seconds=30.0,
                inference_seconds=2.0,
                resident_vram_mb=3000.0 if cuda else None,
                peak_vram_mb=3500.0 if cuda else None,
            ),
        ),
        text="公開鍵暗号",
        language="Japanese",
    )


class FakeTranscriber:
    def __init__(self, calls: list):
        self.calls = calls

    def transcribe(self, audio_path, *, language):
        self.calls.append(("transcribe", audio_path, language))
        return "テストです", "Japanese"


def run_fake(
    audio: pathlib.Path,
    output: pathlib.Path,
    *,
    model: str = "Qwen/Qwen3-ASR-1.7B",
    revision: str | None = None,
    load_transcriber=None,
) -> tuple[dict, list]:
    calls: list = []

    def load(**kwargs):
        calls.append(("load", kwargs))
        return FakeTranscriber(calls)

    artifact = run_transcription(
        audio_path=audio,
        output_path=output,
        model=model,
        revision=revision,
        device="cpu",
        language="Japanese",
        load_transcriber=load_transcriber or load,
        package_versions=lambda: PACKAGES,
    )
    return artifact, calls


def test_cpu_artifact_separates_cold_load_and_warm_inference():
    artifact = make_artifact()

    assert artifact["schema_version"] == 2
    assert artifact["runtime"] == {
        "audio_seconds": 10.0,
        "model_load_seconds": 30.0,
        "inference_seconds": 2.0,
        "rtf": 0.2,
    }
    assert artifact["segments"] == [{
        "start_ms": 0,
        "end_ms": 10_000,
        "text": "公開鍵暗号",
        "language": "Japanese",
    }]


def test_cuda_artifact_requires_measured_vram():
    artifact = make_artifact("cuda:0")
    assert artifact["runtime"]["resident_vram_mb"] == 3000.0
    assert artifact["runtime"]["peak_vram_mb"] == 3500.0

    with pytest.raises(ValueError, match="VRAM"):
        build_runtime(
            device="cuda:0",
            audio_seconds=1.0,
            measurement=RuntimeMeasurement(1.0, 1.0, None, None),
        )


@pytest.mark.parametrize(
    ("mutate", "message"),
    [
        (lambda a: a.update(schema_version=1), "schema_version"),
        (lambda a: a["engine"].update(revision=None), "revision"),
        (lambda a: a["engine"].update(package_versions={}), "package_versions"),
        (lambda a: a["engine"].pop("inference_config"), "engine keys"),
        (lambda a: a["engine"].update(backend="vllm"), "backend"),
        (lambda a: a["runtime"].update(rtf=math.inf), "finite"),
        (lambda a: a["runtime"].update(rtf=0.5), "rtf"),
        (lambda a: a["runtime"].update(peak_vram_mb=1.0), "runtime keys"),
        (lambda a: a["segments"].append(dict(a["segments"][0])), "exactly one"),
        (lambda a: a["segments"][0].update(text=None), "text"),
        (lambda a: a["segments"][0].update(end_ms=9_000), "end_ms"),
        (lambda a: a["segments"][0].update(start_ms=True), "start_ms"),
    ],
)
def test_validate_asr_artifact_rejects_incomplete_or_mistyped_fields(
    mutate,
    message,
):
    artifact = copy.deepcopy(make_artifact())
    mutate(artifact)

    with pytest.raises(ValueError, match=message):
        validate_asr_artifact(artifact)


def test_validate_asr_artifact_rejects_cuda_runtime_without_vram():
    artifact = make_artifact("cuda:0")
    del artifact["runtime"]["resident_vram_mb"]

    with pytest.raises(ValueError, match="runtime keys"):
        validate_asr_artifact(artifact)


def test_run_transcription_records_reproduction_conditions(tmp_path):
    audio = tmp_path / "sample.wav"
    output = tmp_path / "result.json"
    make_wav(audio)

    artifact, calls = run_fake(audio, output)

    assert calls == [
        (
            "load",
            {
                "model": "Qwen/Qwen3-ASR-1.7B",
                "revision": "7278e1e70fe206f11671096ffdd38061171dd6e5",
                "device": "cpu",
            },
        ),
        ("transcribe", audio, "Japanese"),
    ]
    saved = json.loads(output.read_text(encoding="utf-8"))
    assert saved == artifact
    assert saved["engine"]["package_versions"] == PACKAGES
    assert saved["engine"]["inference_config"] == {
        "dtype": "bfloat16",
        "device_map": "cpu",
        "max_inference_batch_size": 1,
        "max_new_tokens": 4096,
        "language": "Japanese",
        "context": "",
    }
    assert saved["segments"][0]["text"] == "テストです"
    assert saved["runtime"]["audio_seconds"] == 1.0


def test_run_transcription_removes_stale_output_when_model_load_fails(
    tmp_path,
):
    audio = tmp_path / "sample.wav"
    output = tmp_path / "result.json"
    make_wav(audio)
    output.write_text('{"stale":true}', encoding="utf-8")

    def fail(**kwargs):
        raise RuntimeError("load failed")

    with pytest.raises(RuntimeError, match="load failed"):
        run_fake(audio, output, load_transcriber=fail)

    assert not output.exists()


def test_custom_model_without_revision_fails_and_clears_stale_output(
    tmp_path,
):
    audio = tmp_path / "sample.wav"
    output = tmp_path / "result.json"
    make_wav(audio)
    output.write_text('{"stale":true}', encoding="utf-8")

    with pytest.raises(ValueError, match="revision"):
        run_fake(audio, output, model="example/custom-asr")

    assert not output.exists()
