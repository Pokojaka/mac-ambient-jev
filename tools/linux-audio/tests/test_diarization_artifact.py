import copy
import math

import pytest

from common.artifact import (
    build_diarization_artifact,
    build_engine,
    build_runtime,
    validate_diarization_artifact,
)
from common.runtime_metrics import RuntimeMeasurement


def make_artifact(device: str = "cuda:0") -> dict:
    cuda = device != "cpu"
    return build_diarization_artifact(
        engine=build_engine(
            name="nemotron-3-diarization",
            model="nvidia/Nemotron-3-Diarization",
            revision="test-revision",
            backend="nemo",
            device=device,
            package_versions={"nemo_toolkit": "2.6.0"},
            inference_config={"profile": "offline-30.4s"},
        ),
        runtime=build_runtime(
            device=device,
            audio_seconds=2.0,
            measurement=RuntimeMeasurement(
                model_load_seconds=12.0,
                inference_seconds=0.5,
                resident_vram_mb=900.0 if cuda else None,
                peak_vram_mb=1200.0 if cuda else None,
            ),
        ),
        spans=[
            {
                "start_ms": 0,
                "end_ms": 1000,
                "speaker": {"kind": "tracked", "index": 1},
            },
            {
                "start_ms": 1000,
                "end_ms": 1500,
                "speaker": {"kind": "other"},
            },
            {
                "start_ms": 1500,
                "end_ms": 2000,
                "speaker": {"kind": "unknown"},
            },
        ],
        raw_spans=[
            {"start_ms": 0, "end_ms": 1000, "speaker_label": "speaker_0"},
            {"start_ms": 1000, "end_ms": 2000, "speaker_label": "speaker_1"},
        ],
        overflow_resolver={
            "embedding_model": "titanet",
            "embedding_revision": "embed-rev",
            "match_threshold": 0.82,
            "ambiguity_margin": 0.04,
            "min_clean_speech_ms": 750,
        },
    )


def test_diarization_artifact_uses_public_speaker_schema():
    artifact = make_artifact()

    assert artifact["schema_version"] == 2
    assert artifact["speaker_policy"] == {
        "tracked_limit": 7,
        "overflow": "other",
    }
    assert artifact["runtime"]["rtf"] == 0.25
    assert artifact["runtime"]["resident_vram_mb"] == 900.0
    assert artifact["runtime"]["peak_vram_mb"] == 1200.0


@pytest.mark.parametrize(
    "speaker",
    [
        {"kind": "tracked", "index": 8},
        {"kind": "tracked"},
        {"kind": "other", "index": 1},
        {"kind": "unknown", "index": None},
        {"kind": "speaker_0"},
    ],
)
def test_diarization_artifact_rejects_invalid_speaker_identity(speaker):
    artifact = make_artifact()
    artifact["spans"][0]["speaker"] = speaker

    with pytest.raises(ValueError, match="speaker"):
        validate_diarization_artifact(artifact)


@pytest.mark.parametrize(
    ("mutate", "message"),
    [
        (lambda a: a["spans"][0].update(end_ms=0), "span time range"),
        (lambda a: a["raw_spans"][0].update(end_ms=0), "raw span time range"),
        (lambda a: a["raw_spans"][0].update(speaker_label=" "), "speaker_label"),
        (lambda a: a.pop("raw_spans"), "artifact keys"),
        (lambda a: a.pop("overflow_resolver"), "artifact keys"),
        (
            lambda a: a["overflow_resolver"].update(match_threshold=1.5),
            "match_threshold",
        ),
        (
            lambda a: a["overflow_resolver"].update(embedding_revision=""),
            "embedding_revision",
        ),
        (
            lambda a: a["overflow_resolver"].update(min_clean_speech_ms=0),
            "min_clean_speech_ms",
        ),
        (lambda a: a["engine"].update(revision=None), "revision"),
        (lambda a: a["runtime"].update(peak_vram_mb=math.nan), "peak_vram_mb"),
        (lambda a: a["runtime"].pop("resident_vram_mb"), "runtime keys"),
    ],
)
def test_diarization_artifact_rejects_incomplete_or_invalid_fields(
    mutate,
    message,
):
    artifact = copy.deepcopy(make_artifact())
    mutate(artifact)

    with pytest.raises(ValueError, match=message):
        validate_diarization_artifact(artifact)


def test_cpu_diarization_artifact_must_not_claim_vram():
    artifact = make_artifact("cpu")
    assert "peak_vram_mb" not in artifact["runtime"]

    artifact["runtime"]["peak_vram_mb"] = 1.0
    with pytest.raises(ValueError, match="runtime keys"):
        validate_diarization_artifact(artifact)
