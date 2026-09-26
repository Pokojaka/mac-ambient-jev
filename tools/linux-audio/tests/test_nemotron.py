from __future__ import annotations

import math

from diarization.nemotron3 import (
    PROFILES,
    apply_nemo_profile,
    parse_nemo_segments,
    run_diarization,
)
from diarization.speaker_overflow import (
    SpeakerOverflowResolver,
    resolve_spans_with_embeddings,
)


def test_nemotron_profiles_match_recommended_values():
    assert PROFILES["offline-30.4s"] == (
        264, 40, 340, 40, 300
    )
    assert PROFILES["ultra-low-0.32s"] == (
        264, 264, 3, 1, 222
    )


def test_parse_nemo_segments_preserves_overlap():
    spans = parse_nemo_segments([
        "0.400 2.100 speaker_0",
        "1.800 3.250 speaker_1",
    ])
    assert spans[0]["start_ms"] == 400
    assert spans[0]["end_ms"] == 2100
    assert spans[1]["start_ms"] == 1800


def test_apply_profile_updates_model():
    class Modules:
        pass

    class Model:
        def __init__(self):
            self.sortformer_modules = Modules()
            self.checked = False

        def _check_streaming_parameters(self):
            self.checked = True

    model = Model()
    apply_nemo_profile(model, "very-low-0.64s")
    assert model.sortformer_modules.chunk_len == 6
    assert model.sortformer_modules.chunk_right_context == 2
    assert model.checked


def one_hot(index: int, size: int = 10) -> list[float]:
    return [
        1.0 if position == index else 0.0
        for position in range(size)
    ]


def test_overflow_resolver_tracks_seven_then_uses_other():
    resolver = SpeakerOverflowResolver(
        match_threshold=0.8,
        ambiguity_margin=0.05,
    )
    assigned = [
        resolver.resolve(one_hot(index))
        for index in range(10)
    ]

    assert [x["index"] for x in assigned[:7]] == list(
        range(1, 8)
    )
    assert [x["kind"] for x in assigned[7:]] == [
        "other", "other", "other"
    ]
    assert resolver.resolve(one_hot(2)) == {
        "kind": "tracked",
        "index": 3,
    }


def test_overflow_resolver_keeps_borderline_as_unknown():
    resolver = SpeakerOverflowResolver(
        match_threshold=0.8,
        ambiguity_margin=0.05,
    )
    for index in range(7):
        resolver.resolve(one_hot(index))

    candidate = [
        0.78,
        math.sqrt(1 - 0.78 ** 2),
    ] + [0.0] * 8

    assert resolver.resolve(candidate) == {
        "kind": "unknown"
    }



def test_resolve_spans_with_embeddings_emits_public_schema():
    resolver = SpeakerOverflowResolver(
        match_threshold=0.8,
        ambiguity_margin=0.05,
    )
    raw = [
        {
            "start_ms": index * 1000,
            "end_ms": (index + 1) * 1000,
            "speaker_label": f"raw-{index}",
        }
        for index in range(10)
    ]

    resolved = resolve_spans_with_embeddings(
        list(reversed(raw)),
        embedding_for_span=lambda span: one_hot(
            int(span["speaker_label"].split("-")[1])
        ),
        resolver=resolver,
    )

    assert [span["start_ms"] for span in resolved] == [
        index * 1000
        for index in range(10)
    ]
    assert [
        span["speaker"]["index"]
        for span in resolved[:7]
    ] == list(range(1, 8))
    assert [
        span["speaker"]["kind"]
        for span in resolved[7:]
    ] == ["other", "other", "other"]
    assert all(
        "speaker_label" not in span
        for span in resolved
    )



def test_run_diarization_writes_resolved_artifact(tmp_path):
    import json
    import wave

    audio = tmp_path / "audio.wav"
    with wave.open(str(audio), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(16_000)
        wav.writeframes(b"\x00\x00" * 16_000)

    output = tmp_path / "diarization.json"
    raw = [
        {
            "start_ms": index * 100,
            "end_ms": (index + 1) * 100,
            "speaker_label": f"raw-{index}",
        }
        for index in range(10)
    ]
    times = iter([10.0, 10.25])

    artifact = run_diarization(
        audio_path=audio,
        output_path=output,
        profile="offline-30.4s",
        model="nvidia/Nemotron-3-Diarization",
        revision="test-revision",
        device="cuda:0",
        embedding_model="test-embedding",
        match_threshold=0.8,
        ambiguity_margin=0.05,
        diarize_raw=lambda _audio, _profile: raw,
        embedding_for_span=lambda span: one_hot(
            int(span["speaker_label"].split("-")[1])
        ),
        clock=lambda: next(times),
    )

    assert output.is_file()
    assert json.loads(output.read_text()) == artifact
    assert artifact["runtime"]["audio_seconds"] == 1.0
    assert artifact["runtime"]["inference_seconds"] == 0.25
    assert artifact["overflow_resolver"] == {
        "embedding_model": "test-embedding",
        "match_threshold": 0.8,
        "ambiguity_margin": 0.05,
    }
    assert [
        span["speaker"]["kind"]
        for span in artifact["spans"][7:]
    ] == ["other", "other", "other"]


def test_run_diarization_removes_stale_output_on_failure(
    tmp_path,
):
    import wave

    audio = tmp_path / "audio.wav"
    with wave.open(str(audio), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(16_000)
        wav.writeframes(b"\x00\x00" * 1600)

    output = tmp_path / "diarization.json"
    output.write_text('{"stale": true}')

    def fail(_audio, _profile):
        raise RuntimeError("boom")

    with pytest.raises(RuntimeError, match="boom"):
        run_diarization(
            audio_path=audio,
            output_path=output,
            profile="offline-30.4s",
            model="nvidia/Nemotron-3-Diarization",
            revision=None,
            device="cuda:0",
            embedding_model="test-embedding",
            match_threshold=0.8,
            ambiguity_margin=0.05,
            diarize_raw=fail,
            embedding_for_span=lambda span: one_hot(0),
        )

    assert not output.exists()
