import pathlib
import subprocess
import wave

import pytest

from common.audio import normalize_to_wav


def make_wav(
    path: pathlib.Path,
    rate: int = 8_000,
    channels: int = 2,
) -> None:
    with wave.open(str(path), "wb") as wav:
        wav.setnchannels(channels)
        wav.setsampwidth(2)
        wav.setframerate(rate)
        wav.writeframes(
            b"\x00\x00" * channels * 800
        )


def test_normalize_to_wav_outputs_mono_16khz(
    tmp_path,
):
    source = tmp_path / "source.wav"
    output = tmp_path / "normalized.wav"
    make_wav(source)

    normalize_to_wav(source, output)

    with wave.open(str(output), "rb") as wav:
        assert wav.getnchannels() == 1
        assert wav.getframerate() == 16_000
        assert wav.getsampwidth() == 2
    assert sorted(path.name for path in tmp_path.iterdir()) == [
        "normalized.wav",
        "source.wav",
    ]


def test_normalize_failure_removes_stale_output(
    monkeypatch,
    tmp_path,
):
    source = tmp_path / "source.wav"
    output = tmp_path / "normalized.wav"
    make_wav(source)
    output.write_bytes(b"stale")

    def fail(*args, **kwargs):
        raise subprocess.CalledProcessError(
            1,
            args[0],
        )

    monkeypatch.setattr(subprocess, "run", fail)

    with pytest.raises(subprocess.CalledProcessError):
        normalize_to_wav(source, output)

    assert not output.exists()
    assert [path.name for path in tmp_path.iterdir()] == ["source.wav"]


@pytest.mark.parametrize("source_alias", [False, True])
def test_normalize_rejects_same_source_and_destination_without_deleting_audio(
    tmp_path, source_alias,
):
    original = tmp_path / "original.wav"
    make_wav(original)
    before = original.read_bytes()
    source = original
    if source_alias:
        source = tmp_path / "source-link.wav"
        source.symlink_to(original)

    with pytest.raises(ValueError, match="source and destination must be different files"):
        normalize_to_wav(source, original)

    assert original.exists()
    assert original.read_bytes() == before
