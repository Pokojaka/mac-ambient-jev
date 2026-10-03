from __future__ import annotations

import argparse
import pathlib
from collections.abc import Callable
from dataclasses import dataclass
from typing import Any, Protocol

from common.artifact import (
    DIARIZATION_BACKEND,
    DIARIZATION_ENGINE_NAME,
    build_diarization_artifact,
    build_engine,
    build_runtime,
    installed_package_versions,
)
from common.audio import wav_duration_seconds
from common.files import write_json_atomic
from common.runtime_metrics import measure_load_and_inference
from diarization.speaker_embedding import (
    DEFAULT_TITANET_MODEL,
    DEFAULT_TITANET_REVISION,
    load_titanet_adapter,
)
from diarization.speaker_overflow import (
    SpeakerOverflowResolver,
    resolve_spans_with_embeddings,
)


DEFAULT_MODEL = "nvidia/Nemotron-3-Diarization"
DEFAULT_MODEL_FILENAME = "Nemotron-3-Diarization.nemo"
DEFAULT_MODEL_REVISION = (
    "0e224186f30112a1b555f2ee402e2be781146535"
)
PACKAGES = ("nemo_toolkit", "torch", "huggingface-hub")
BATCH_SIZE = 1

PROFILES = {
    "offline-30.4s": (264, 40, 340, 40, 300),
    "low-1.04s": (264, 264, 9, 4, 222),
    "very-low-0.64s": (264, 264, 6, 2, 222),
    "ultra-low-0.32s": (264, 264, 3, 1, 222),
}


def profile_parameters(profile: str) -> dict[str, int]:
    try:
        cache, fifo, chunk, right, update = PROFILES[profile]
    except KeyError as exc:
        raise ValueError(f"unknown profile: {profile}") from exc
    return {
        "spkcache_len": cache,
        "fifo_len": fifo,
        "chunk_len": chunk,
        "chunk_right_context": right,
        "spkcache_update_period": update,
    }


def apply_nemo_profile(model, profile: str) -> None:
    modules = model.sortformer_modules
    for name, value in profile_parameters(profile).items():
        setattr(modules, name, value)
    model._check_streaming_parameters()


def inference_config(profile: str) -> dict[str, Any]:
    return {
        "profile": profile,
        "streaming": profile_parameters(profile),
        "batch_size": BATCH_SIZE,
    }


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


class Diarizer(Protocol):
    def diarize(self, audio_path: pathlib.Path) -> list[dict]: ...


class SpeakerEmbedder(Protocol):
    def embedding_for_span(
        self,
        audio_path: pathlib.Path,
        span: dict,
    ) -> list[float]: ...


@dataclass(frozen=True)
class LoadedModels:
    diarizer: Diarizer
    embedder: SpeakerEmbedder


class NemotronDiarizer:
    def __init__(self, model: Any) -> None:
        self._model = model

    def diarize(self, audio_path: pathlib.Path) -> list[dict]:
        prediction = self._model.diarize(
            audio=[str(audio_path)],
            batch_size=BATCH_SIZE,
        )
        if len(prediction) != 1:
            raise RuntimeError(
                f"Nemotron returned {len(prediction)} results for one audio"
            )
        return parse_nemo_segments(list(prediction[0]))


def load_nemotron_diarizer(
    *,
    model_name: str,
    revision: str,
    device: str,
    profile: str,
) -> NemotronDiarizer:
    if not revision:
        raise ValueError("Nemotron revision must be pinned")

    from huggingface_hub import hf_hub_download
    from nemo.collections.asr.models import SortformerEncLabelModel

    checkpoint = hf_hub_download(
        repo_id=model_name,
        filename=DEFAULT_MODEL_FILENAME,
        revision=revision,
    )
    model = SortformerEncLabelModel.restore_from(
        restore_path=str(checkpoint),
        map_location=device,
        strict=True,
    )
    model.eval()
    apply_nemo_profile(model, profile)
    return NemotronDiarizer(model)


def run_diarization(
    *,
    audio_path: pathlib.Path,
    output_path: pathlib.Path,
    profile: str,
    model: str,
    revision: str,
    device: str,
    embedding_model: str,
    embedding_revision: str,
    match_threshold: float,
    ambiguity_margin: float,
    min_clean_speech_ms: int,
    load_models: Callable[[], LoadedModels],
    package_versions: Callable[[], dict[str, str]],
) -> dict:
    output_path.unlink(missing_ok=True)
    if not audio_path.is_file():
        raise FileNotFoundError(audio_path)
    if min_clean_speech_ms <= 0:
        raise ValueError("min_clean_speech_ms must be positive")
    config = inference_config(profile)
    audio_seconds = wav_duration_seconds(audio_path)
    resolver = SpeakerOverflowResolver(
        match_threshold=match_threshold,
        ambiguity_margin=ambiguity_margin,
    )

    def infer(models: LoadedModels) -> tuple[list[dict], list[dict]]:
        raw_spans = models.diarizer.diarize(audio_path)
        resolved_spans = resolve_spans_with_embeddings(
            raw_spans,
            embedding_for_span=lambda span:
                models.embedder.embedding_for_span(audio_path, span),
            resolver=resolver,
            min_clean_speech_ms=min_clean_speech_ms,
        )
        return raw_spans, resolved_spans

    (raw_spans, resolved_spans), measurement = measure_load_and_inference(
        device=device,
        load=load_models,
        infer=infer,
    )

    artifact = build_diarization_artifact(
        engine=build_engine(
            name=DIARIZATION_ENGINE_NAME,
            model=model,
            revision=revision,
            backend=DIARIZATION_BACKEND,
            device=device,
            package_versions=package_versions(),
            inference_config=config,
        ),
        runtime=build_runtime(
            device=device,
            audio_seconds=audio_seconds,
            measurement=measurement,
        ),
        spans=resolved_spans,
        raw_spans=raw_spans,
        overflow_resolver={
            "embedding_model": embedding_model,
            "embedding_revision": embedding_revision,
            "match_threshold": match_threshold,
            "ambiguity_margin": ambiguity_margin,
            "min_clean_speech_ms": min_clean_speech_ms,
        },
    )
    write_json_atomic(output_path, artifact)
    return artifact


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Run Nemotron 3 diarization and map "
            "speaker spans to Speaker 1...7 / OTHER / UNKNOWN"
        )
    )
    parser.add_argument("audio", type=pathlib.Path)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument(
        "--profile",
        choices=tuple(PROFILES),
        required=True,
    )
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument(
        "--revision",
        default=DEFAULT_MODEL_REVISION,
        help=(
            "Pinned Hugging Face revision for the "
            "Nemotron .nemo checkpoint."
        ),
    )
    parser.add_argument("--device", required=True)
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
        help="Margin below match threshold mapped to UNKNOWN.",
    )
    parser.add_argument(
        "--min-clean-speech-ms",
        type=int,
        required=True,
        help=(
            "Minimum contiguous non-overlapping speech used "
            "for speaker resolution and arrival order."
        ),
    )
    args = parser.parse_args(argv)

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
        load_models=lambda: LoadedModels(
            diarizer=load_nemotron_diarizer(
                model_name=args.model,
                revision=args.revision,
                device=args.device,
                profile=args.profile,
            ),
            embedder=load_titanet_adapter(
                model_name=args.embedding_model,
                revision=args.embedding_revision,
                device=args.device,
            ),
        ),
        package_versions=lambda: installed_package_versions(PACKAGES),
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
