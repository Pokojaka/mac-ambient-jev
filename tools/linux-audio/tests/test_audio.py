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
