import copy
import dataclasses
import json

import pytest

from common.artifact import (
    build_asr_artifact,
    build_diarization_artifact,
    build_engine,
    build_runtime,
)
from common.baseline import (
    build_asr_baseline_record,
    build_diarization_baseline_record,
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
        "reference_characters": 10,
        "hypothesis_characters": 10,
    }


def write_json(path, payload):
    path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
    return path


def asr_inputs(tmp_path, *, normalized_cer=0.0, dtype="bfloat16"):
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
                "raw": cer(0.1),
                "normalized": cer(normalized_cer),
                "normalizer_version": "1",
            },
        ),
        "audio_path": audio,
        "reference_path": reference,
    }


def asr_record(tmp_path, **kwargs):
    tmp_path.mkdir(parents=True, exist_ok=True)
    return build_asr_baseline_record(
        **asr_inputs(tmp_path, **kwargs),
        reference_kind="verbatim",
    )


def test_asr_baseline_records_engine_conditions_and_metrics(tmp_path):
    record = asr_record(tmp_path)

    assert record.engine["package_versions"]["qwen-asr"] == "0.0.6"
    assert record.engine["inference_config"]["dtype"] == "bfloat16"
    assert record.conditions == {
        "reference_kind": "verbatim",
        "normalizer_version": "1",
    }
    assert record.metrics == {
        "raw_cer": 0.1,
        "normalized_cer": 0.0,
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
        build_asr_baseline_record(**inputs, reference_kind="verbatim")


def test_asr_baseline_rejects_unknown_reference_kind(tmp_path):
    with pytest.raises(ValueError, match="reference_kind"):
        build_asr_baseline_record(
            **asr_inputs(tmp_path),
            reference_kind="cleaned",
        )


def test_compare_reports_metric_delta(tmp_path):
    result = compare_baseline(
        asr_record(tmp_path / "a", normalized_cer=0.10),
        asr_record(tmp_path / "b", normalized_cer=0.12),
    )
    assert result["normalized_cer"]["baseline"] == 0.10
    assert result["normalized_cer"]["current"] == 0.12
    assert result["normalized_cer"]["delta"] == pytest.approx(0.02)


def test_compare_rejects_different_inference_config(tmp_path):
    with pytest.raises(ValueError, match="engine"):
        compare_baseline(
            asr_record(tmp_path / "a"),
            asr_record(tmp_path / "b", dtype="float16"),
        )


def test_compare_rejects_different_reference_kind(tmp_path):
    baseline = asr_record(tmp_path)
    current = dataclasses.replace(
        baseline,
        conditions={**baseline.conditions, "reference_kind": "content"},
    )

    with pytest.raises(ValueError, match="conditions"):
        compare_baseline(baseline, current)


def test_record_with_missing_metric_is_invalid(tmp_path):
    baseline = asr_record(tmp_path)
    metrics = dict(baseline.metrics)
    del metrics["peak_vram_mb"]

    with pytest.raises(ValueError, match="metrics must be exactly"):
        dataclasses.replace(baseline, metrics=metrics).validate()


def diarization_evaluation(other_precision):
    return {
        "standard": {
            "der": 0.1,
            "miss_ms": 10,
            "false_alarm_ms": 5,
            "confusion_ms": 20,
            "overlap_recall": 0.8,
            "speaker_switch_boundary_mae_ms": 45.0,
        },
        "collapsed": {
            "der": 0.05,
            "tracked_speaker_confusion_ms": 100,
            "other_precision": other_precision,
            "other_recall": None,
            "other_to_tracked_leakage_ms": 50,
            "tracked_to_other_leakage_ms": 25,
            "unknown_rate": 0.02,
            "overflow_detection_recall": None,
            "overlap_recall": 0.75,
        },
        "evaluator_version": "1",
    }


def diarization_record(tmp_path, other_precision=0.9):
    tmp_path.mkdir(parents=True, exist_ok=True)
    audio = tmp_path / "audio.wav"
    audio.write_bytes(b"audio")
    reference = write_json(tmp_path / "speaker-reference.json", [])
    artifact = build_diarization_artifact(
        engine=build_engine(
            name="nemotron-3-diarization",
            model="nvidia/Nemotron-3-Diarization",
            revision="model-rev",
            backend="nemo",
            device="cuda:0",
            package_versions={"nemo_toolkit": "2.6.0"},
            inference_config={"profile": "offline-30.4s"},
        ),
        runtime=build_runtime(
            device="cuda:0",
            audio_seconds=8.0,
            measurement=CUDA_MEASUREMENT,
        ),
        spans=[],
        raw_spans=[],
        overflow_resolver={
            "embedding_model": "titanet",
            "embedding_revision": "embed-rev",
            "match_threshold": 0.82,
            "ambiguity_margin": 0.04,
            "min_clean_speech_ms": 750,
        },
    )
    return build_diarization_baseline_record(
        artifact_path=write_json(tmp_path / "nemotron3.json", artifact),
        evaluation_path=write_json(
            tmp_path / "diarization-evaluation.json",
            diarization_evaluation(other_precision),
        ),
        audio_path=audio,
        speaker_reference_path=reference,
    )


def test_diarization_baseline_keeps_not_applicable_metrics_as_null(
    tmp_path,
):
    record = diarization_record(tmp_path)

    assert record.conditions["overflow_resolver"]["embedding_revision"] == (
        "embed-rev"
    )
    assert record.conditions["evaluator_version"] == "1"
    assert record.metrics["standard_der"] == 0.1
    assert record.metrics["collapsed_der"] == 0.05
    assert record.metrics["other_recall"] is None
    assert record.metrics["overflow_detection_recall"] is None
    assert record.metrics["peak_vram_mb"] == 3500.0


def test_diarization_compare_reports_null_delta(tmp_path):
    result = compare_baseline(
        diarization_record(tmp_path / "a", other_precision=0.9),
        diarization_record(tmp_path / "b", other_precision=None),
    )
    assert result["other_precision"] == {
        "baseline": 0.9,
        "current": None,
        "delta": None,
    }


def test_diarization_baseline_rejects_missing_metric_key(tmp_path):
    record = diarization_record(tmp_path)
    evaluation = diarization_evaluation(0.9)
    del evaluation["collapsed"]["unknown_rate"]
    write_json(tmp_path / "diarization-evaluation.json", evaluation)

    with pytest.raises(ValueError, match="collapsed.unknown_rate"):
        build_diarization_baseline_record(
            artifact_path=tmp_path / "nemotron3.json",
            evaluation_path=tmp_path / "diarization-evaluation.json",
            audio_path=tmp_path / "audio.wav",
            speaker_reference_path=tmp_path / "speaker-reference.json",
        )
    assert record.metrics["unknown_rate"] == 0.02


def test_null_is_rejected_for_always_defined_metrics(tmp_path):
    record = diarization_record(tmp_path)
    metrics = copy.deepcopy(record.metrics)
    metrics["collapsed_der"] = None

    with pytest.raises(ValueError, match="collapsed_der"):
        dataclasses.replace(record, metrics=metrics).validate()
