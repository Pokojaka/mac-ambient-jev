import json

import pytest

from common.baseline import (
    BaselineRecord,
    compare_baseline,
    build_diarization_baseline_record,
    load_baseline,
)


def make_record(cer: float = 0.10) -> BaselineRecord:
    return BaselineRecord(
        schema_version=1,
        kind="asr",
        engine="qwen3-asr",
        model="Qwen/Qwen3-ASR-1.7B",
        revision="abc123",
        backend="transformers",
        device="cuda:0",
        evaluator_version="asr-eval-v1",
        corpus={
            "voicevox-ja-core-v1": "deadbeef" * 8,
        },
        metrics={
            "normalized_cer": cer,
            "rtf": 0.2,
        },
    )


def test_baseline_round_trip(tmp_path):
    record = make_record()
    path = tmp_path / "baseline.json"
    record.write(path)
    assert load_baseline(path) == record


def test_baseline_requires_reproducibility_metadata(
    tmp_path,
):
    path = tmp_path / "bad.json"
    path.write_text(
        json.dumps({
            "schema_version": 1,
            "kind": "asr",
        }),
        encoding="utf-8",
    )
    with pytest.raises(ValueError, match="engine"):
        load_baseline(path)


def test_baseline_compare_rejects_revision_mismatch():
    baseline = make_record()
    current = make_record()
    current = BaselineRecord(
        **{
            **current.__dict__,
            "revision": "different",
        }
    )
    with pytest.raises(ValueError, match="revision"):
        compare_baseline(baseline, current)


def test_baseline_compare_reports_metric_delta():
    result = compare_baseline(
        make_record(0.10),
        make_record(0.12),
    )
    assert result["normalized_cer"]["baseline"] == 0.10
    assert result["normalized_cer"]["current"] == 0.12
    assert result["normalized_cer"]["delta"] == pytest.approx(
        0.02
    )


def test_diarization_baseline_collects_reproducibility_metadata(
    tmp_path,
):
    audio = tmp_path / "audio.wav"
    audio.write_bytes(b"audio")
    reference = tmp_path / "speaker-reference.json"
    reference.write_text("[]", encoding="utf-8")
    artifact = tmp_path / "nemotron3.json"
    artifact.write_text(
        json.dumps({
            "schema_version": 1,
            "engine": {
                "name": "nemotron-3-diarization",
                "model": "nvidia/Nemotron-3-Diarization",
                "revision": "model-rev",
                "profile": "offline-30.4s",
                "backend": "nemo",
                "device": "cuda:0",
            },
            "overflow_resolver": {
                "embedding_model": "titanet",
                "embedding_revision": "embed-rev",
                "match_threshold": 0.82,
                "ambiguity_margin": 0.04,
                "min_clean_speech_ms": 750,
            },
            "runtime": {
                "rtf": 0.25,
                "peak_vram_mb": 1536.0,
            },
        }),
        encoding="utf-8",
    )
    evaluation = tmp_path / "diarization-evaluation.json"
    evaluation.write_text(
        json.dumps({
            "standard": {
                "der": 0.1,
                "overlap_recall": 0.8,
                "speaker_switch_boundary_mae_ms": 45.0,
            },
            "collapsed": {
                "der": 0.05,
                "tracked_speaker_confusion_ms": 100,
                "other_precision": 0.9,
                "other_recall": 0.85,
                "other_to_tracked_leakage_ms": 50,
                "tracked_to_other_leakage_ms": 25,
                "unknown_rate": 0.02,
                "overflow_detection_recall": 0.95,
                "overlap_recall": 0.75,
            },
        }),
        encoding="utf-8",
    )

    record = build_diarization_baseline_record(
        artifact_path=artifact,
        evaluation_path=evaluation,
        audio_path=audio,
        speaker_reference_path=reference,
    )

    assert record.kind == "diarization"
    assert record.engine == "nemotron-3-diarization"
    assert record.revision == "model-rev"
    assert record.corpus["audio"] != record.corpus[
        "speaker_reference"
    ]
    assert len(record.corpus["audio"]) == 64
    assert record.configuration["profile"] == "offline-30.4s"
    assert (
        record.configuration["overflow_resolver"]
        ["embedding_revision"]
        == "embed-rev"
    )
    assert record.metrics["standard_der"] == 0.1
    assert record.metrics["collapsed_der"] == 0.05
    assert record.metrics["rtf"] == 0.25
    assert record.metrics["peak_vram_mb"] == 1536.0


def test_baseline_compare_rejects_configuration_mismatch():
    baseline = BaselineRecord(
        **{
            **make_record().__dict__,
            "configuration": {"profile": "offline"},
        }
    )
    current = BaselineRecord(
        **{
            **make_record().__dict__,
            "configuration": {"profile": "streaming"},
        }
    )

    with pytest.raises(ValueError, match="configuration"):
        compare_baseline(baseline, current)
