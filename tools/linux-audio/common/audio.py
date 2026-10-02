from __future__ import annotations

import pathlib
import subprocess
import tempfile


def normalize_to_wav(
    source: pathlib.Path,
    destination: pathlib.Path,
    sample_rate: int = 16_000,
) -> pathlib.Path:
    if not source.is_file():
        raise FileNotFoundError(source)
    if sample_rate <= 0:
        raise ValueError("sample_rate must be positive")

    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.unlink(missing_ok=True)
    _, temp_name = tempfile.mkstemp(
        suffix=".wav",
        dir=destination.parent,
    )
    temporary = pathlib.Path(temp_name)
    temporary.unlink(missing_ok=True)

    try:
        subprocess.run(
            [
                "ffmpeg",
                "-hide_banner",
                "-loglevel", "error",
                "-y",
                "-i", str(source),
                "-ac", "1",
                "-ar", str(sample_rate),
                "-c:a", "pcm_s16le",
                str(temporary),
            ],
            check=True,
        )
        temporary.replace(destination)
        return destination
    except Exception:
        temporary.unlink(missing_ok=True)
        destination.unlink(missing_ok=True)
        raise
