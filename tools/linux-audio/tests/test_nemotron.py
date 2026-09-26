from __future__ import annotations

import math

from diarization.nemotron3 import (
    PROFILES,
    apply_nemo_profile,
    parse_nemo_segments,
)
from diarization.speaker_overflow import (
    SpeakerOverflowResolver,
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
