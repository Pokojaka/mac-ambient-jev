from __future__ import annotations

import copy
import math

import pytest

from common.artifact import (
    SCHEMA_VERSION,
    build_asr_artifact,
    build_engine,
    build_runtime,
    validate_asr_artifact,
)
from common.runtime_metrics import RuntimeMeasurement


ONNX_CONFIG = {
    "language": "ja",
    "quantization": "int4",
    "minimum_input_seconds": 0.02,
    "mel_variant": "whisper-slaney-128-nfft400-hop160-reflect-global-log10",
    "max_new_tokens": 448,
    "no_repeat_ngram": "3 when input_seconds > 15; disabled otherwise",
    "intra_op_threads": 4,
    "inter_op_threads": 1,
    "cpu_memory_arena": False,
    "segmentation": "silero-final-transcript",
}
ONNX_PACKAGES = {"onnxruntime": "1.31.0", "numpy": "2.2.0"}


def make_artifact(
    *,
    audio_seconds: float,
    device: str,
    inference_config: dict,
    package_versions: dict,
) -> dict:
    cuda = device.startswith("cuda")
    engine = build_engine(
        name="qwen3-asr",
        model="Qwen/Qwen3-ASR-1.7B",
        revision="abc123",
        backend="onnxruntime",
        device=device,
        package_versions=package_versions,
        inference_config=inference_config,
    )
    runtime = build_runtime(
        device=device,
        audio_seconds=audio_seconds,
        measurement=RuntimeMeasurement(
            model_load_seconds=30.0,
            inference_seconds=2.0,
            resident_vram_mb=3000.0 if cuda else None,
            peak_vram_mb=3500.0 if cuda else None,
        ),
    )
    return {
        "schema_version": SCHEMA_VERSION,
        "engine": engine,
        "segments": [{
            "start_ms": 0,
            "end_ms": round(audio_seconds * 1000),
            "text": "公開鍵暗号",
            "language": "Japanese",
        }],
        "runtime": runtime,
    }


@pytest.mark.parametrize("audio_seconds", [10.0, 18.464])
def test_valid_cpu_onnx_artifact_and_builder(audio_seconds: float):
    artifact = make_artifact(
        audio_seconds=audio_seconds,
        device="cpu",
        inference_config={**ONNX_CONFIG},
        package_versions={**ONNX_PACKAGES},
    )
    assert artifact["engine"]["inference_config"]["no_repeat_ngram"] == (
        "3 when input_seconds > 15; disabled otherwise"
    )
    validate_asr_artifact(artifact)

    rebuilt = build_asr_artifact(
        engine=artifact["engine"],
        runtime=artifact["runtime"],
        text="公開鍵暗号",
        language="Japanese",
    )
    assert rebuilt == artifact


@pytest.mark.parametrize(
    ("mutate", "message"),
    [
        (lambda c: c.pop("language"), "inference_config keys"),
        (lambda c: c.update(extra="not allowed"), "inference_config keys"),
        (lambda c: c.update(language=None), "language"),
        (lambda c: c.update(quantization="int8"), "quantization"),
        (lambda c: c.update(minimum_input_seconds=True), "minimum_input_seconds"),
        (lambda c: c.update(minimum_input_seconds=0.01), "minimum_input_seconds"),
        (lambda c: c.update(mel_variant="other"), "mel_variant"),
        (lambda c: c.update(max_new_tokens=True), "max_new_tokens"),
        (lambda c: c.update(max_new_tokens=449), "max_new_tokens"),
        (lambda c: c.update(no_repeat_ngram="3"), "no_repeat_ngram"),
        (lambda c: c.update(no_repeat_ngram="disabled"), "no_repeat_ngram"),
        (lambda c: c.update(intra_op_threads=True), "intra_op_threads"),
        (lambda c: c.update(intra_op_threads=0), "intra_op_threads"),
        (lambda c: c.update(intra_op_threads=2**31), "intra_op_threads"),
        (lambda c: c.update(inter_op_threads=1.0), "inter_op_threads"),
        (lambda c: c.update(inter_op_threads=2), "inter_op_threads"),
        (lambda c: c.update(cpu_memory_arena=0), "cpu_memory_arena"),
        (lambda c: c.update(cpu_memory_arena=True), "cpu_memory_arena"),
        (lambda c: c.update(segmentation="other"), "segmentation"),
    ],
)
def test_onnx_config_requires_exact_keys_and_values(mutate, message):
    artifact = make_artifact(
        audio_seconds=10.0,
        device="cpu",
        inference_config={**ONNX_CONFIG},
        package_versions={**ONNX_PACKAGES},
    )
    mutate(artifact["engine"]["inference_config"])

    with pytest.raises(ValueError, match=message):
        validate_asr_artifact(artifact)


def test_onnx_config_accepts_finite_numeric_minimum_input_seconds():
    artifact = make_artifact(
        audio_seconds=10.0,
        device="cpu",
        inference_config={**ONNX_CONFIG},
        package_versions={**ONNX_PACKAGES},
    )
    artifact["engine"]["inference_config"]["minimum_input_seconds"] = 0.02
    validate_asr_artifact(artifact)

    for value in (math.inf, math.nan, "0.02", False):
        invalid = copy.deepcopy(artifact)
        invalid["engine"]["inference_config"]["minimum_input_seconds"] = value
        with pytest.raises(ValueError, match="minimum_input_seconds"):
            validate_asr_artifact(invalid)


def test_onnx_artifact_requires_onnxruntime_package():
    artifact = make_artifact(
        audio_seconds=10.0,
        device="cpu",
        inference_config={**ONNX_CONFIG},
        package_versions={"numpy": "2.2.0"},
    )

    with pytest.raises(ValueError, match="package_versions.onnxruntime"):
        validate_asr_artifact(artifact)


def test_onnx_artifact_rejects_cuda_device():
    artifact = make_artifact(
        audio_seconds=10.0,
        device="cuda:0",
        inference_config={**ONNX_CONFIG},
        package_versions={**ONNX_PACKAGES},
    )

    with pytest.raises(ValueError, match="requires device 'cpu'"):
        validate_asr_artifact(artifact)


def test_asr_artifact_rejects_unknown_backend_explicitly():
    artifact = make_artifact(
        audio_seconds=10.0,
        device="cpu",
        inference_config={**ONNX_CONFIG},
        package_versions={**ONNX_PACKAGES},
    )
    artifact["engine"]["backend"] = "other"

    with pytest.raises(ValueError, match="unsupported ASR backend 'other'"):
        validate_asr_artifact(artifact)


@pytest.mark.parametrize("field", ["model", "revision"])
def test_onnx_artifact_keeps_shared_nonempty_model_fields(field: str):
    artifact = make_artifact(
        audio_seconds=10.0,
        device="cpu",
        inference_config={**ONNX_CONFIG},
        package_versions={**ONNX_PACKAGES},
    )
    artifact["engine"][field] = "  "

    with pytest.raises(ValueError, match=field):
        validate_asr_artifact(artifact)


@pytest.mark.parametrize(
    ("mutate", "message"),
    [
        (lambda a: a["segments"].append(dict(a["segments"][0])), "exactly one"),
        (lambda a: a["runtime"].update(extra=1), "runtime keys"),
        (lambda a: a["runtime"].update(rtf=math.inf), "finite"),
        (lambda a: a["runtime"].update(rtf=0.5), "rtf"),
        (lambda a: a["runtime"].update(audio_seconds=0), "positive"),
    ],
)
def test_onnx_artifact_keeps_single_envelope_and_runtime_strictness(
    mutate,
    message: str,
):
    artifact = make_artifact(
        audio_seconds=10.0,
        device="cpu",
        inference_config={**ONNX_CONFIG},
        package_versions={**ONNX_PACKAGES},
    )
    mutate(artifact)

    with pytest.raises(ValueError, match=message):
        validate_asr_artifact(artifact)
