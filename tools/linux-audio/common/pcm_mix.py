from __future__ import annotations

from array import array
import json
import pathlib
import wave


RATE = 16_000


def read_clip(path: pathlib.Path) -> array:
    with wave.open(str(path), "rb") as wav:
        if (
            wav.getnchannels() != 1
            or wav.getsampwidth() != 2
            or wav.getframerate() != RATE
        ):
            raise ValueError("expected mono PCM16 16000 Hz")
        raw = wav.readframes(wav.getnframes())
    samples = array("h")
    samples.frombytes(raw)
    return samples


def mix(
    placements: list[tuple[str, pathlib.Path, int]],
    output: pathlib.Path,
    reference: pathlib.Path,
) -> None:
    loaded = []
    length = 0
    spans = []
    for label, path, start_ms in placements:
        clip = read_clip(path)
        start = round(start_ms * RATE / 1000)
        end = start + len(clip)
        length = max(length, end)
        loaded.append((clip, start))
        spans.append({
            "speaker_label": label,
            "start_ms": start_ms,
            "end_ms": round(end * 1000 / RATE),
        })

    values = [0] * length
    for clip, start in loaded:
        for offset, sample in enumerate(clip):
            values[start + offset] += sample

    pcm = array(
        "h",
        (max(-32768, min(32767, x)) for x in values),
    )
    with wave.open(str(output), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(RATE)
        wav.writeframes(pcm.tobytes())

    reference.write_text(
        json.dumps(
            spans,
            ensure_ascii=False,
            indent=2,
        ) + "\n",
        encoding="utf-8",
    )
