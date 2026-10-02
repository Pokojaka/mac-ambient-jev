import json
import wave

from common.pcm_mix import mix


def make_wav(path, value, frames):
    sample = int(value).to_bytes(
        2,
        "little",
        signed=True,
    )
    with wave.open(str(path), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(16_000)
        wav.writeframes(sample * frames)


def test_pcm_mix_preserves_overlap_and_reference(
    tmp_path,
):
    first = tmp_path / "first.wav"
    second = tmp_path / "second.wav"
    output = tmp_path / "mix.wav"
    reference = tmp_path / "reference.json"
    make_wav(first, 1_000, 1_600)
    make_wav(second, 2_000, 1_600)

    mix(
        [
            ("a", first, 0),
            ("b", second, 50),
        ],
        output,
        reference,
    )

    spans = json.loads(
        reference.read_text(encoding="utf-8")
    )
    assert spans == [
        {
            "speaker_label": "a",
            "start_ms": 0,
            "end_ms": 100,
        },
        {
            "speaker_label": "b",
            "start_ms": 50,
            "end_ms": 150,
        },
    ]

    with wave.open(str(output), "rb") as wav:
        data = wav.readframes(wav.getnframes())
        assert wav.getnframes() == 2_400

    assert int.from_bytes(
        data[1_600:1_602],
        "little",
        signed=True,
    ) == 3_000
