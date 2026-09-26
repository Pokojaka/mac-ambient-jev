from __future__ import annotations

PROFILES = {
    "offline-30.4s": (264, 40, 340, 40, 300),
    "low-1.04s": (264, 264, 9, 4, 222),
    "very-low-0.64s": (264, 264, 6, 2, 222),
    "ultra-low-0.32s": (264, 264, 3, 1, 222),
}


def apply_nemo_profile(model, profile: str) -> None:
    try:
        cache, fifo, chunk, right, update = PROFILES[profile]
    except KeyError as exc:
        raise ValueError(f"unknown profile: {profile}") from exc

    modules = model.sortformer_modules
    modules.spkcache_len = cache
    modules.fifo_len = fifo
    modules.chunk_len = chunk
    modules.chunk_right_context = right
    modules.spkcache_update_period = update
    model._check_streaming_parameters()


def parse_nemo_segments(lines: list[str]) -> list[dict]:
    result = []
    for line in lines:
        fields = line.strip().split()
        if len(fields) != 3:
            raise ValueError(f"invalid segment: {line!r}")
        start, end = float(fields[0]), float(fields[1])
        if not 0 <= start < end:
            raise ValueError(f"invalid time range: {line!r}")
        result.append({
            "start_ms": int(round(start * 1000)),
            "end_ms": int(round(end * 1000)),
            "speaker_label": fields[2],
        })
    return result


def diarize(audio_path: str, profile: str = "offline-30.4s") -> list[dict]:
    from nemo.collections.asr.models import SortformerEncLabelModel

    model = SortformerEncLabelModel.from_pretrained(
        "nvidia/Nemotron-3-Diarization"
    )
    model.eval()
    apply_nemo_profile(model, profile)
    prediction = model.diarize(audio=[audio_path], batch_size=1)
    if not prediction:
        raise RuntimeError("Nemotron returned no result")
    return parse_nemo_segments(list(prediction[0]))
