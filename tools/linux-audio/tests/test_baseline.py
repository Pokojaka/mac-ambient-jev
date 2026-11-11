import dataclasses
import json

import pytest

from common.artifact import build_asr_artifact, build_engine, build_runtime
from common.baseline import (
    build_asr_baseline_record,
    compare_baseline,
    load_baseline,
)
from common.runtime_metrics import RuntimeMeasurement


CUDA_MEASUREMENT = RuntimeMeasurement(
    model_load_seconds=20.0,
    inference_seconds=2.0,
    resident_vram_mb=3000.0,
    peak_vram_mb=3500.0,
)


def cer(rate: float) -> dict:
    return {
        "rate": rate,
        "substitutions": 1,
        "deletions": 0,
        "insertions": 0,
        "required_reference_characters": 8,
        "optional_reference_characters": 2,
        "hypothesis_characters": 10,
    }


def write_json(path, payload):
    path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
    return path


def asr_inputs(tmp_path, *, cer_rate=0.0, dtype="bfloat16"):
    audio = tmp_path / "audio.wav"
    audio.write_bytes(b"audio")
    reference = tmp_path / "reference.txt"
    reference.write_text("今日は音声認識です。\n", encoding="utf-8")
    artifact = build_asr_artifact(
        engine=build_engine(
            name="qwen3-asr",
            model="Qwen/Qwen3-ASR-1.7B",
            revision="model-rev",
            backend="transformers",
            device="cuda:0",
            package_versions={"qwen-asr": "0.0.6", "torch": "2.10.0"},
            inference_config={"dtype": dtype, "language": "Japanese"},
        ),
        runtime=build_runtime(
            device="cuda:0",
            audio_seconds=10.0,
            measurement=CUDA_MEASUREMENT,
        ),
        text="今日は音声認識です",
        language="Japanese",
    )
    return {
        "artifact_path": write_json(tmp_path / "qwen3-asr.json", artifact),
        "evaluation_path": write_json(
            tmp_path / "asr-evaluation.json",
            {
                "cer": cer(cer_rate),
                "normalizer_version": "1",
            },
        ),
        "audio_path": audio,
        "reference_path": reference,
    }


def asr_record(tmp_path, **kwargs):
    tmp_path.mkdir(parents=True, exist_ok=True)
    return build_asr_baseline_record(**asr_inputs(tmp_path, **kwargs))


def test_asr_baseline_records_engine_conditions_and_metrics(tmp_path):
    record = asr_record(tmp_path)

    assert record.engine["package_versions"]["qwen-asr"] == "0.0.6"
    assert record.engine["inference_config"]["dtype"] == "bfloat16"
    assert record.conditions == {"normalizer_version": "1"}
    assert record.metrics == {
        "cer": 0.0,
        "rtf": 0.2,
        "model_load_seconds": 20.0,
        "resident_vram_mb": 3000.0,
        "peak_vram_mb": 3500.0,
    }
    assert set(record.corpus) == {"audio", "reference"}


def test_baseline_round_trip(tmp_path):
    record = asr_record(tmp_path)
    path = tmp_path / "baseline.json"
    record.write(path)
    assert load_baseline(path) == record


def test_load_baseline_rejects_missing_conditions(tmp_path):
    record = asr_record(tmp_path)
    payload = dataclasses.asdict(record)
    del payload["conditions"]
    path = write_json(tmp_path / "bad.json", payload)

    with pytest.raises(ValueError, match="baseline keys"):
        load_baseline(path)


def test_asr_baseline_requires_normalizer_version(tmp_path):
    inputs = asr_inputs(tmp_path)
    evaluation = json.loads(inputs["evaluation_path"].read_text())
    del evaluation["normalizer_version"]
    write_json(inputs["evaluation_path"], evaluation)

    with pytest.raises(ValueError, match="normalizer_version"):
        build_asr_baseline_record(**inputs)


def test_compare_reports_metric_delta(tmp_path):
    result = compare_baseline(
        asr_record(tmp_path / "a", cer_rate=0.10),
        asr_record(tmp_path / "b", cer_rate=0.12),
    )
    assert result["cer"]["baseline"] == 0.10
    assert result["cer"]["current"] == 0.12
    assert result["cer"]["delta"] == pytest.approx(0.02)


def test_compare_rejects_different_inference_config(tmp_path):
    with pytest.raises(ValueError, match="engine"):
        compare_baseline(
            asr_record(tmp_path / "a"),
            asr_record(tmp_path / "b", dtype="float16"),
        )


def test_compare_rejects_different_normalizer_version(tmp_path):
    baseline = asr_record(tmp_path)
    current = dataclasses.replace(
        baseline,
        conditions={**baseline.conditions, "normalizer_version": "2"},
    )

    with pytest.raises(ValueError, match="conditions"):
        compare_baseline(baseline, current)


def test_record_with_missing_metric_is_invalid(tmp_path):
    baseline = asr_record(tmp_path)
    metrics = dict(baseline.metrics)
    del metrics["peak_vram_mb"]

    with pytest.raises(ValueError, match="metrics must be exactly"):
        dataclasses.replace(baseline, metrics=metrics).validate()
