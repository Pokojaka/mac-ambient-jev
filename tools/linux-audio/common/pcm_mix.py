from __future__ import annotations

from array import array
import pathlib
import wave

from common.audio import SAMPLE_RATE
from common.files import write_json_atomic


# A PCM16 sample at or above this magnitude (about -40 dBFS) counts as
# speech activity. Leading and trailing samples below it are the TTS
# engine's pre- and post-phoneme silence and stay out of the DER reference.
SPEECH_ACTIVITY_THRESHOLD = 328


def read_clip(path: pathlib.Path) -> array:
    with wave.open(str(path), "rb") as wav:
        if (
            wav.getnchannels() != 1
            or wav.getsampwidth() != 2
            or wav.getframerate() != SAMPLE_RATE
        ):
            raise ValueError("expected mono PCM16 16000 Hz")
        raw = wav.readframes(wav.getnframes())
    samples = array("h")
    samples.frombytes(raw)
    return samples


def speech_activity_frames(
    clip: array,
    path: pathlib.Path,
) -> tuple[int, int]:
    active = [
        index
        for index, sample in enumerate(clip)
        if abs(sample) >= SPEECH_ACTIVITY_THRESHOLD
    ]
    if not active:
        raise ValueError(f"{path} contains no speech activity")
    return active[0], active[-1] + 1


def _frames_to_ms(frames: int) -> int:
    return round(frames * 1000 / SAMPLE_RATE)


def mix(
    placements: list[tuple[str, pathlib.Path, int]],
    output: pathlib.Path,
    reference: pathlib.Path,
) -> list[dict]:
    """Mixes clips at their start offsets and writes the DER reference.

    Each reference span covers the clip's speech activity, not its full
    length.
    """
    loaded = []
    length = 0
    spans = []
    for label, path, start_ms in placements:
        clip = read_clip(path)
        start = round(start_ms * SAMPLE_RATE / 1000)
        length = max(length, start + len(clip))
        loaded.append((clip, start))
        first, last = speech_activity_frames(clip, path)
        spans.append({
            "speaker_label": label,
            "start_ms": _frames_to_ms(start + first),
            "end_ms": _frames_to_ms(start + last),
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
        wav.setframerate(SAMPLE_RATE)
        wav.writeframes(pcm.tobytes())

    write_json_atomic(reference, spans)
    return spans


def overlap_ratio(spans: list[dict]) -> float:
    """Share of speech time during which two or more speakers talk."""
    boundaries = sorted(
        {span["start_ms"] for span in spans}
        | {span["end_ms"] for span in spans}
    )
    speech_ms = 0
    overlap_ms = 0
    for start, end in zip(boundaries, boundaries[1:]):
        active = sum(
            1
            for span in spans
            if span["start_ms"] < end and span["end_ms"] > start
        )
        if active >= 1:
            speech_ms += end - start
        if active >= 2:
            overlap_ms += end - start
    if speech_ms == 0:
        raise ValueError("timeline contains no speech")
    return overlap_ms / speech_ms
