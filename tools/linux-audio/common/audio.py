from __future__ import annotations

import os
import pathlib
import subprocess
import tempfile
import wave


SAMPLE_RATE = 16_000


def wav_duration_seconds(path: pathlib.Path) -> float:
    with wave.open(str(path), "rb") as wav:
        return wav.getnframes() / wav.getframerate()


def normalize_to_wav(
    source: pathlib.Path,
    destination: pathlib.Path,
) -> pathlib.Path:
    if not source.is_file():
        raise FileNotFoundError(source)

    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.unlink(missing_ok=True)
    fd, temp_name = tempfile.mkstemp(
        suffix=".wav",
        dir=destination.parent,
    )
    os.close(fd)
    temporary = pathlib.Path(temp_name)

    try:
        subprocess.run(
            [
                "ffmpeg",
                "-hide_banner",
                "-loglevel", "error",
                "-y",
                "-i", str(source),
                "-ac", "1",
                "-ar", str(SAMPLE_RATE),
                "-c:a", "pcm_s16le",
                str(temporary),
            ],
            check=True,
        )
        temporary.replace(destination)
        return destination
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise
