from __future__ import annotations

import json
import math
import wave

import pytest

from diarization.nemotron3 import (
    LoadedModels,
    apply_nemo_profile,
    parse_nemo_segments,
    run_diarization,
)
from diarization.speaker_overflow import (
    SpeakerOverflowResolver,
    first_clean_subspan,
    resolve_spans_with_embeddings,
)


PACKAGES = {"nemo_toolkit": "2.6.0", "torch": "2.10.0"}


def one_hot(index: int, size: int = 10) -> list[float]:
    return [
        1.0 if position == index else 0.0
        for position in range(size)
    ]


def borderline(score: float) -> list[float]:
    """An embedding whose cosine similarity to one_hot(0) is score."""
    return [score, math.sqrt(1 - score ** 2)] + [0.0] * 8


def make_resolver() -> SpeakerOverflowResolver:
    return SpeakerOverflowResolver(
        match_threshold=0.8,
        ambiguity_margin=0.05,
    )


def make_wav(path, frames: int = 16_000) -> None:
    with wave.open(str(path), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(16_000)
        wav.writeframes(b"\x00\x00" * frames)


def span(start: int, end: int, label: str) -> dict:
    return {"start_ms": start, "end_ms": end, "speaker_label": label}


def test_parse_nemo_segments_preserves_overlap():
    spans = parse_nemo_segments([
        "0.400 2.100 speaker_0",
        "1.800 3.250 speaker_1",
    ])
    assert spans == [
        span(400, 2100, "speaker_0"),
        span(1800, 3250, "speaker_1"),
    ]


def test_apply_profile_updates_model_and_checks_parameters():
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

    with pytest.raises(ValueError, match="unknown profile"):
        apply_nemo_profile(model, "fastest")


def test_overflow_resolver_tracks_seven_then_uses_other():
    resolver = make_resolver()
    assigned = [
        resolver.resolve(one_hot(index))
        for index in range(10)
    ]

    assert [x["index"] for x in assigned[:7]] == list(range(1, 8))
    assert [x["kind"] for x in assigned[7:]] == ["other"] * 3
    assert resolver.resolve(one_hot(2)) == {"kind": "tracked", "index": 3}


@pytest.mark.parametrize("registered", [1, 7])
def test_ambiguous_score_is_unknown_before_and_after_seven_speakers(
    registered,
):
    resolver = make_resolver()
    for index in range(registered):
        resolver.resolve(one_hot(index))

    assert resolver.resolve(borderline(0.78)) == {"kind": "unknown"}
    assert len(resolver.references) == registered


def test_clearly_new_voice_opens_a_slot_below_the_ambiguity_band():
    resolver = make_resolver()
    resolver.resolve(one_hot(0))

    assert resolver.resolve(borderline(0.70)) == {
        "kind": "tracked",
        "index": 2,
    }


def test_first_clean_subspan_uses_non_overlapping_part():
    spans = [
        span(0, 1400, "a"),
        span(1000, 2000, "b"),
        span(3000, 3300, "c"),
        span(5000, 6000, "d"),
        span(5200, 5600, "d"),
    ]

    assert first_clean_subspan(
        spans[1], spans, min_clean_speech_ms=500
    ) == (1400, 2000)
    assert first_clean_subspan(
        spans[0], spans, min_clean_speech_ms=500
    ) == (0, 1000)
    assert first_clean_subspan(
        spans[2], spans, min_clean_speech_ms=500
    ) is None
    assert first_clean_subspan(
        spans[3], spans, min_clean_speech_ms=500
    ) == (5000, 6000)


def test_span_without_clean_speech_is_unknown_and_never_registers():
    resolver = make_resolver()
    calls = []

    resolved = resolve_spans_with_embeddings(
        [span(0, 2000, "a"), span(500, 900, "b")],
        embedding_for_span=lambda clean: calls.append(clean)
            or one_hot(len(calls)),
        resolver=resolver,
        min_clean_speech_ms=500,
    )

    assert calls == [{"start_ms": 0, "end_ms": 500}]
    assert [item["speaker"] for item in resolved] == [
        {"kind": "tracked", "index": 1},
        {"kind": "unknown"},
    ]
    assert len(resolver.references) == 1


def test_arrival_order_follows_first_clean_utterance():
    # a backchannels inside b's turn, so a only arrives with its later
    # clean utterance, after c.
    spans = [
        span(0, 3000, "b"),
        span(200, 600, "a"),
        span(3500, 4500, "c"),
        span(5000, 6000, "a"),
    ]
    voices = {600: "b", 3500: "c", 5000: "a"}
    embeddings = {"b": one_hot(0), "c": one_hot(1), "a": one_hot(2)}

    resolved = resolve_spans_with_embeddings(
        spans,
        embedding_for_span=lambda clean:
            embeddings[voices[clean["start_ms"]]],
        resolver=make_resolver(),
        min_clean_speech_ms=500,
    )

    assert [item["speaker"] for item in resolved] == [
        {"kind": "tracked", "index": 1},
        {"kind": "unknown"},
        {"kind": "tracked", "index": 2},
        {"kind": "tracked", "index": 3},
    ]


def test_resolved_spans_use_public_schema_in_start_order():
    raw = [span(index * 1000, (index + 1) * 1000, f"raw-{index}")
           for index in range(10)]

    resolved = resolve_spans_with_embeddings(
        list(reversed(raw)),
        embedding_for_span=lambda clean: one_hot(clean["start_ms"] // 1000),
        resolver=make_resolver(),
        min_clean_speech_ms=500,
    )

    assert [item["start_ms"] for item in resolved] == [
        index * 1000 for index in range(10)
    ]
    assert [item["speaker"]["kind"] for item in resolved[7:]] == [
        "other"
    ] * 3
    assert all(set(item) == {"start_ms", "end_ms", "speaker"}
               for item in resolved)


class FakeDiarizer:
    def __init__(self, raw):
        self.raw = raw

    def diarize(self, audio_path):
        return self.raw


class FakeEmbedder:
    def embedding_for_span(self, audio_path, clean):
        return one_hot(clean["start_ms"] // 100)


def run_fake(audio, output, raw, **overrides):
    arguments = {
        "audio_path": audio,
        "output_path": output,
        "profile": "offline-30.4s",
        "model": "nvidia/Nemotron-3-Diarization",
        "revision": "test-revision",
        "device": "cpu",
        "embedding_model": "test-embedding",
        "embedding_revision": "test-embedding-revision",
        "match_threshold": 0.8,
        "ambiguity_margin": 0.05,
        "min_clean_speech_ms": 50,
        "load_models": lambda: LoadedModels(
            diarizer=FakeDiarizer(raw),
            embedder=FakeEmbedder(),
        ),
        "package_versions": lambda: PACKAGES,
    }
    arguments.update(overrides)
    return run_diarization(**arguments)


def test_run_diarization_writes_artifact_with_reproduction_conditions(
    tmp_path,
):
    audio = tmp_path / "audio.wav"
    output = tmp_path / "diarization.json"
    make_wav(audio)
    raw = [span(index * 100, (index + 1) * 100, f"raw-{index}")
           for index in range(10)]

    artifact = run_fake(audio, output, raw)

    assert json.loads(output.read_text()) == artifact
    assert artifact["schema_version"] == 2
    assert artifact["raw_spans"] == raw
    assert artifact["engine"]["package_versions"] == PACKAGES
    assert artifact["engine"]["inference_config"] == {
        "profile": "offline-30.4s",
        "streaming": {
            "spkcache_len": 264,
            "fifo_len": 40,
            "chunk_len": 340,
            "chunk_right_context": 40,
            "spkcache_update_period": 300,
        },
        "batch_size": 1,
    }
    assert artifact["overflow_resolver"]["min_clean_speech_ms"] == 50
    assert set(artifact["runtime"]) == {
        "audio_seconds",
        "model_load_seconds",
        "inference_seconds",
        "rtf",
    }
    assert [item["speaker"]["kind"] for item in artifact["spans"][7:]] == [
        "other"
    ] * 3


def test_run_diarization_removes_stale_output_when_model_load_fails(
    tmp_path,
):
    audio = tmp_path / "audio.wav"
    output = tmp_path / "diarization.json"
    make_wav(audio)
    output.write_text('{"stale": true}')

    def fail():
        raise RuntimeError("load failed")

    with pytest.raises(RuntimeError, match="load failed"):
        run_fake(audio, output, [], load_models=fail)

    assert not output.exists()


def test_run_diarization_rejects_nonpositive_clean_speech_gate(tmp_path):
    audio = tmp_path / "audio.wav"
    make_wav(audio)

    with pytest.raises(ValueError, match="min_clean_speech_ms"):
        run_fake(audio, tmp_path / "out.json", [], min_clean_speech_ms=0)
