import json
import wave

import pytest

from common.pcm_mix import (
    SPEECH_ACTIVITY_THRESHOLD,
    mix,
    overlap_ratio,
)


def make_wav(path, value, frames, *, silence_frames=0):
    sample = int(value).to_bytes(2, "little", signed=True)
    silence = b"\x00\x00" * silence_frames
    with wave.open(str(path), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(16_000)
        wav.writeframes(silence + sample * frames + silence)


def test_pcm_mix_sums_overlap_and_writes_reference(tmp_path):
    first = tmp_path / "first.wav"
    second = tmp_path / "second.wav"
    output = tmp_path / "mix.wav"
    reference = tmp_path / "reference.json"
    make_wav(first, 1_000, 1_600)
    make_wav(second, 2_000, 1_600)

    spans = mix(
        [("a", first, 0), ("b", second, 50)],
        output,
        reference,
    )

    assert spans == [
        {"speaker_label": "a", "start_ms": 0, "end_ms": 100},
        {"speaker_label": "b", "start_ms": 50, "end_ms": 150},
    ]
    assert json.loads(reference.read_text(encoding="utf-8")) == spans
    with wave.open(str(output), "rb") as wav:
        data = wav.readframes(wav.getnframes())
        assert wav.getnframes() == 2_400
    assert int.from_bytes(data[1_600:1_602], "little", signed=True) == 3_000


def test_reference_excludes_leading_and_trailing_tts_silence(tmp_path):
    clip = tmp_path / "clip.wav"
    # 100 ms of near-silence, 200 ms of speech, 100 ms of near-silence.
    make_wav(clip, 5_000, 3_200, silence_frames=1_600)

    spans = mix(
        [("a", clip, 1_000)],
        tmp_path / "mix.wav",
        tmp_path / "reference.json",
    )

    assert spans == [
        {"speaker_label": "a", "start_ms": 1_100, "end_ms": 1_300},
    ]


def test_clip_without_speech_activity_is_rejected(tmp_path):
    clip = tmp_path / "quiet.wav"
    make_wav(clip, SPEECH_ACTIVITY_THRESHOLD - 1, 1_600)

    with pytest.raises(ValueError, match="no speech activity"):
        mix([("a", clip, 0)], tmp_path / "mix.wav", tmp_path / "ref.json")


def test_overlap_ratio_is_overlap_share_of_speech_time():
    spans = [
        {"speaker_label": "a", "start_ms": 0, "end_ms": 1_000},
        {"speaker_label": "b", "start_ms": 750, "end_ms": 1_500},
        {"speaker_label": "c", "start_ms": 3_000, "end_ms": 3_500},
    ]

    assert overlap_ratio(spans) == pytest.approx(250 / 2_000)
