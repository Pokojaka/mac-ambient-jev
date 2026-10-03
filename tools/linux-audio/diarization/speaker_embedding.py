from __future__ import annotations

import math
import pathlib
import tempfile
import wave
from collections.abc import Sequence
from typing import Any


DEFAULT_TITANET_MODEL = (
    "nvidia/speakerverification_en_titanet_large"
)
DEFAULT_TITANET_FILENAME = (
    "speakerverification_en_titanet_large.nemo"
)
DEFAULT_TITANET_REVISION = (
    "fa8ee5ddf24f3d3fffc1212d791e0922e5bfb53d"
)


def crop_wav_segment(
    source: pathlib.Path,
    destination: pathlib.Path,
    *,
    start_ms: int,
    end_ms: int,
) -> None:
    if start_ms < 0 or end_ms <= start_ms:
        raise ValueError("invalid span time range")

    with wave.open(str(source), "rb") as input_wav:
        channels = input_wav.getnchannels()
        sample_width = input_wav.getsampwidth()
        frame_rate = input_wav.getframerate()
        frame_count = input_wav.getnframes()

        if channels != 1 or frame_rate != 16_000:
            raise ValueError(
                "speaker embedding requires 16000 Hz mono WAV"
            )

        start_frame = round(start_ms * frame_rate / 1000)
        end_frame = round(end_ms * frame_rate / 1000)
        if end_frame > frame_count:
            raise ValueError(
                f"speaker span {start_ms}-{end_ms} ms extends past "
                f"the audio end ({frame_count} frames)"
            )

        input_wav.setpos(start_frame)
        frames = input_wav.readframes(
            end_frame - start_frame
        )

    destination.parent.mkdir(
        parents=True,
        exist_ok=True,
    )
    with wave.open(str(destination), "wb") as output_wav:
        output_wav.setnchannels(channels)
        output_wav.setsampwidth(sample_width)
        output_wav.setframerate(frame_rate)
        output_wav.writeframes(frames)


def embedding_to_vector(value: Any) -> list[float]:
    for method in ("detach", "cpu"):
        if hasattr(value, method):
            value = getattr(value, method)()
    if hasattr(value, "tolist"):
        value = value.tolist()

    while (
        isinstance(value, Sequence)
        and not isinstance(value, (str, bytes))
        and len(value) == 1
        and isinstance(value[0], Sequence)
        and not isinstance(value[0], (str, bytes))
    ):
        value = value[0]

    if (
        not isinstance(value, Sequence)
        or isinstance(value, (str, bytes))
        or not value
    ):
        raise ValueError(
            "speaker embedding must be a non-empty vector"
        )

    vector: list[float] = []
    for item in value:
        if isinstance(item, bool) or not isinstance(
            item,
            (int, float),
        ):
            raise ValueError(
                "speaker embedding must contain numbers"
            )
        number = float(item)
        if not math.isfinite(number):
            raise ValueError(
                "speaker embedding values must be finite"
            )
        vector.append(number)
    return vector


class TitaNetSpeakerEmbeddingAdapter:
    def __init__(self, model: Any) -> None:
        self.model = model

    def embedding_for_span(
        self,
        audio_path: pathlib.Path,
        span: dict,
    ) -> list[float]:
        start_ms = span.get("start_ms")
        end_ms = span.get("end_ms")
        if (
            not isinstance(start_ms, int)
            or isinstance(start_ms, bool)
            or not isinstance(end_ms, int)
            or isinstance(end_ms, bool)
        ):
            raise ValueError(
                "span start_ms/end_ms must be integers"
            )

        with tempfile.TemporaryDirectory(
            prefix="mac-ambient-jev-speaker-"
        ) as temp_dir:
            crop_path = (
                pathlib.Path(temp_dir) / "span.wav"
            )
            crop_wav_segment(
                audio_path,
                crop_path,
                start_ms=start_ms,
                end_ms=end_ms,
            )
            embedding = self.model.get_embedding(
                str(crop_path)
            )
        return embedding_to_vector(embedding)


def load_titanet_adapter(
    *,
    model_name: str,
    revision: str,
    device: str,
) -> TitaNetSpeakerEmbeddingAdapter:
    if not revision:
        raise ValueError(
            "TitaNet revision must be pinned"
        )

    from huggingface_hub import hf_hub_download
    from nemo.collections.asr.models import EncDecSpeakerLabelModel

    checkpoint = hf_hub_download(
        repo_id=model_name,
        filename=DEFAULT_TITANET_FILENAME,
        revision=revision,
    )
    model = EncDecSpeakerLabelModel.restore_from(
        restore_path=str(checkpoint),
        map_location=device,
        strict=True,
    )
    model.eval()
    return TitaNetSpeakerEmbeddingAdapter(model)
