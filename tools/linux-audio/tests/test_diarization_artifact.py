import pytest

from common.artifact import (
    build_diarization_artifact,
    validate_diarization_artifact,
)


def test_build_diarization_artifact_uses_public_speaker_schema():
    artifact = build_diarization_artifact(
        model="nvidia/Nemotron-3-Diarization",
        revision="test-revision",
        profile="offline-30.4s",
        backend="nemo",
        device="cuda:0",
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
        audio_seconds=2.0,
        inference_seconds=0.5,
    )

    assert artifact["speaker_policy"] == {
        "tracked_limit": 7,
        "overflow": "other",
    }
    assert artifact["runtime"]["rtf"] == 0.25
    assert artifact["spans"][0]["speaker"] == {
        "kind": "tracked",
        "index": 1,
    }
    validate_diarization_artifact(artifact)


@pytest.mark.parametrize(
    "speaker",
    [
        {"kind": "tracked", "index": 8},
        {"kind": "tracked"},
        {"kind": "other", "index": 1},
        {"kind": "unknown", "index": 1},
        {"kind": "speaker_0"},
    ],
)
def test_diarization_artifact_rejects_invalid_speaker_identity(
    speaker,
):
    with pytest.raises(ValueError, match="speaker"):
        build_diarization_artifact(
            model="nvidia/Nemotron-3-Diarization",
            revision=None,
            profile="offline-30.4s",
            backend="nemo",
            device="cuda:0",
            spans=[{
                "start_ms": 0,
                "end_ms": 1000,
                "speaker": speaker,
            }],
            audio_seconds=1.0,
            inference_seconds=1.0,
        )


def test_diarization_artifact_rejects_invalid_span_range():
    with pytest.raises(ValueError, match="time range"):
        build_diarization_artifact(
            model="nvidia/Nemotron-3-Diarization",
            revision=None,
            profile="offline-30.4s",
            backend="nemo",
            device="cuda:0",
            spans=[{
                "start_ms": 1000,
                "end_ms": 1000,
                "speaker": {"kind": "other"},
            }],
            audio_seconds=1.0,
            inference_seconds=1.0,
        )
