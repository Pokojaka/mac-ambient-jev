import json

import pytest

from common.baseline import (
    BaselineRecord,
    compare_baseline,
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
