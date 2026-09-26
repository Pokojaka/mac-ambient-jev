import math
import wave

import pytest

from diarization.speaker_embedding import (
    TitaNetSpeakerEmbeddingAdapter,
    crop_wav_segment,
    embedding_to_vector,
)


def make_wav(path, *, channels=1, rate=16_000, frames=1600):
    with wave.open(str(path), "wb") as wav:
        wav.setnchannels(channels)
        wav.setsampwidth(2)
        wav.setframerate(rate)
        wav.writeframes(b"\x00\x00" * channels * frames)


def test_crop_wav_segment_preserves_16k_mono_and_duration(tmp_path):
    source = tmp_path / "source.wav"
    destination = tmp_path / "crop.wav"
    make_wav(source)

    crop_wav_segment(
        source,
        destination,
        start_ms=25,
        end_ms=75,
    )

    with wave.open(str(destination), "rb") as wav:
        assert wav.getnchannels() == 1
        assert wav.getframerate() == 16_000
        assert wav.getsampwidth() == 2
        assert wav.getnframes() == 800


def test_crop_wav_segment_rejects_non_16k_mono(tmp_path):
    source = tmp_path / "source.wav"
    destination = tmp_path / "crop.wav"
    make_wav(source, channels=2)

    with pytest.raises(ValueError, match="16000 Hz mono"):
        crop_wav_segment(
            source,
            destination,
            start_ms=0,
            end_ms=50,
        )


def test_embedding_to_vector_flattens_single_batch():
    assert embedding_to_vector([[0.25, -0.5]]) == [
        0.25,
        -0.5,
    ]


def test_embedding_to_vector_rejects_non_finite_values():
    with pytest.raises(ValueError, match="finite"):
        embedding_to_vector([0.25, math.nan])


def test_titanet_adapter_embeds_cropped_span(tmp_path):
    source = tmp_path / "source.wav"
    make_wav(source, frames=3200)

    class Model:
        def __init__(self):
            self.frames = None

        def get_embedding(self, path):
            with wave.open(str(path), "rb") as wav:
                self.frames = wav.getnframes()
            return [[0.1, 0.2, 0.3]]

    model = Model()
    adapter = TitaNetSpeakerEmbeddingAdapter(model)

    vector = adapter.embedding_for_span(
        source,
        {
            "start_ms": 50,
            "end_ms": 150,
        },
    )

    assert model.frames == 1600
    assert vector == [0.1, 0.2, 0.3]
