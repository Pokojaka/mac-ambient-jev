from __future__ import annotations

import argparse
import pathlib
import time
import wave
from collections.abc import Callable

from common.artifact import (
    build_diarization_artifact,
    write_json_atomic,
)
from diarization.speaker_embedding import (
    DEFAULT_TITANET_MODEL,
    DEFAULT_TITANET_REVISION,
    load_titanet_adapter,
)
from diarization.speaker_overflow import (
    SpeakerOverflowResolver,
    is_clean_speech_span,
    resolve_spans_with_embeddings,
)


DEFAULT_MODEL = "nvidia/Nemotron-3-Diarization"
DEFAULT_MODEL_FILENAME = "Nemotron-3-Diarization.nemo"
DEFAULT_MODEL_REVISION = (
    "0e224186f30112a1b555f2ee402e2be781146535"
)

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
        raise ValueError(
            f"unknown profile: {profile}"
        ) from exc

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
            raise ValueError(
                f"invalid segment: {line!r}"
            )
        start, end = float(fields[0]), float(fields[1])
        if not 0 <= start < end:
            raise ValueError(
                f"invalid time range: {line!r}"
            )
        result.append({
            "start_ms": int(round(start * 1000)),
            "end_ms": int(round(end * 1000)),
            "speaker_label": fields[2],
        })
    return result


def wav_duration_seconds(path: pathlib.Path) -> float:
    try:
        with wave.open(str(path), "rb") as wav:
            rate = wav.getframerate()
            if rate <= 0:
                raise ValueError(
                    "invalid WAV sample rate"
                )
            return wav.getnframes() / rate
    except wave.Error as exc:
        raise ValueError(
            "duration probing requires WAV input"
        ) from exc


def load_nemotron_model(
    *,
    model_name: str = DEFAULT_MODEL,
    revision: str = DEFAULT_MODEL_REVISION,
    device: str = "cuda:0",
    profile: str = "offline-30.4s",
    download_checkpoint=None,
    model_class=None,
):
    if not revision:
        raise ValueError(
            "Nemotron revision must be pinned"
        )

    if download_checkpoint is None:
        from huggingface_hub import hf_hub_download
        download_checkpoint = hf_hub_download

    if model_class is None:
        from nemo.collections.asr.models import (
            SortformerEncLabelModel,
        )
        model_class = SortformerEncLabelModel

    checkpoint = download_checkpoint(
        repo_id=model_name,
        filename=DEFAULT_MODEL_FILENAME,
        revision=revision,
    )
    model = model_class.restore_from(
        restore_path=str(checkpoint),
        map_location=device,
        strict=False,
    )
    model.eval()
    apply_nemo_profile(model, profile)
    return model


def diarize(
    audio_path: pathlib.Path | str,
    profile: str = "offline-30.4s",
    *,
    model_name: str = DEFAULT_MODEL,
    revision: str = DEFAULT_MODEL_REVISION,
    device: str = "cuda:0",
) -> list[dict]:
    model = load_nemotron_model(
        model_name=model_name,
        revision=revision,
        device=device,
        profile=profile,
    )
    prediction = model.diarize(
        audio=[str(audio_path)],
        batch_size=1,
    )
    if not prediction:
        raise RuntimeError(
            "Nemotron returned no result"
        )
    return parse_nemo_segments(
        list(prediction[0])
    )


def run_diarization(
    *,
    audio_path: pathlib.Path,
    output_path: pathlib.Path,
    profile: str,
    model: str,
    revision: str | None,
    device: str,
    embedding_model: str,
    embedding_revision: str,
    match_threshold: float,
    ambiguity_margin: float,
    min_clean_speech_ms: int = 1,
    diarize_raw: Callable[
        [pathlib.Path, str],
        list[dict],
    ],
    embedding_for_span: Callable[
        [dict],
        list[float],
    ],
    clock: Callable[[], float] = time.perf_counter,
) -> dict:
    if not audio_path.is_file():
        raise FileNotFoundError(audio_path)
    if min_clean_speech_ms <= 0:
        raise ValueError(
            "min_clean_speech_ms must be positive"
        )
    output_path.unlink(missing_ok=True)

    audio_seconds = wav_duration_seconds(
        audio_path
    )
    resolver = SpeakerOverflowResolver(
        match_threshold=match_threshold,
        ambiguity_margin=ambiguity_margin,
    )

    started = clock()
    raw_spans = diarize_raw(
        audio_path,
        profile,
    )
    resolved_spans = resolve_spans_with_embeddings(
        raw_spans,
        embedding_for_span=embedding_for_span,
        resolver=resolver,
        eligible_for_resolution=lambda span:
            is_clean_speech_span(
                span,
                raw_spans,
                min_duration_ms=min_clean_speech_ms,
            ),
    )
    inference_seconds = clock() - started
    if inference_seconds < 0:
        raise ValueError(
            "clock moved backwards during diarization"
        )

    artifact = build_diarization_artifact(
        model=model,
        revision=revision,
        profile=profile,
        backend="nemo",
        device=device,
        spans=resolved_spans,
        audio_seconds=audio_seconds,
        inference_seconds=inference_seconds,
        overflow_resolver={
            "embedding_model": embedding_model,
            "embedding_revision": embedding_revision,
            "match_threshold": match_threshold,
            "ambiguity_margin": ambiguity_margin,
            "min_clean_speech_ms": min_clean_speech_ms,
        },
    )
    write_json_atomic(
        output_path,
        artifact,
    )
    return artifact


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Run Nemotron 3 diarization and map "
            "speaker spans to Speaker 1...7 / OTHER / UNKNOWN"
        )
    )
    parser.add_argument(
        "audio",
        type=pathlib.Path,
    )
    parser.add_argument(
        "--output",
        type=pathlib.Path,
        required=True,
    )
    parser.add_argument(
        "--profile",
        choices=tuple(PROFILES),
        default="offline-30.4s",
    )
    parser.add_argument(
        "--model",
        default=DEFAULT_MODEL,
    )
    parser.add_argument(
        "--revision",
        default=DEFAULT_MODEL_REVISION,
        help=(
            "Pinned Hugging Face revision for the "
            "Nemotron .nemo checkpoint."
        ),
    )
    parser.add_argument(
        "--device",
        default="cuda:0",
    )
    parser.add_argument(
        "--embedding-model",
        default=DEFAULT_TITANET_MODEL,
    )
    parser.add_argument(
        "--embedding-revision",
        default=DEFAULT_TITANET_REVISION,
        help=(
            "Pinned Hugging Face revision for the "
            "speaker embedding checkpoint."
        ),
    )
    parser.add_argument(
        "--match-threshold",
        type=float,
        required=True,
        help=(
            "Speaker-match threshold calibrated on "
            "the target Japanese corpus."
        ),
    )
    parser.add_argument(
        "--ambiguity-margin",
        type=float,
        required=True,
        help=(
            "Margin below match threshold mapped to UNKNOWN."
        ),
    )
    parser.add_argument(
        "--min-clean-speech-ms",
        type=int,
        required=True,
        help=(
            "Minimum non-overlapping span length used "
            "for speaker resolution."
        ),
    )
    args = parser.parse_args(argv)

    args.output.unlink(missing_ok=True)
    adapter = load_titanet_adapter(
        model_name=args.embedding_model,
        revision=args.embedding_revision,
        device=args.device,
    )

    run_diarization(
        audio_path=args.audio,
        output_path=args.output,
        profile=args.profile,
        model=args.model,
        revision=args.revision,
        device=args.device,
        embedding_model=args.embedding_model,
        embedding_revision=args.embedding_revision,
        match_threshold=args.match_threshold,
        ambiguity_margin=args.ambiguity_margin,
        min_clean_speech_ms=args.min_clean_speech_ms,
        diarize_raw=lambda audio, profile: diarize(
            audio,
            profile,
            model_name=args.model,
            revision=args.revision,
            device=args.device,
        ),
        embedding_for_span=lambda span:
            adapter.embedding_for_span(
                args.audio,
                span,
            ),
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
