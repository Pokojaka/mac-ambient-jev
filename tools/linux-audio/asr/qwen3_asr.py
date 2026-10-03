from __future__ import annotations

import argparse
import pathlib
from collections.abc import Callable
from typing import Any, Protocol

from common.artifact import (
    ASR_BACKEND,
    ASR_ENGINE_NAME,
    build_asr_artifact,
    build_engine,
    build_runtime,
    installed_package_versions,
)
from common.audio import wav_duration_seconds
from common.files import write_json_atomic
from common.runtime_metrics import measure_load_and_inference

DEFAULT_MODEL = "Qwen/Qwen3-ASR-1.7B"
DEFAULT_MODEL_REVISION = (
    "7278e1e70fe206f11671096ffdd38061171dd6e5"
)
PACKAGES = ("qwen-asr", "torch", "transformers")
DTYPE = "bfloat16"
MAX_INFERENCE_BATCH_SIZE = 1
MAX_NEW_TOKENS = 4096
CONTEXT = ""


class Transcriber(Protocol):
    def transcribe(
        self,
        audio_path: pathlib.Path,
        *,
        language: str,
    ) -> tuple[str, str]: ...


def resolve_model_revision(
    model: str,
    revision: str | None,
) -> str:
    if revision:
        return revision
    if model == DEFAULT_MODEL:
        return DEFAULT_MODEL_REVISION
    raise ValueError(
        "revision is required for custom ASR models"
    )


def inference_config(*, device: str, language: str) -> dict[str, Any]:
    return {
        "dtype": DTYPE,
        "device_map": device,
        "max_inference_batch_size": MAX_INFERENCE_BATCH_SIZE,
        "max_new_tokens": MAX_NEW_TOKENS,
        "language": language,
        "context": CONTEXT,
    }


class QwenTranscriber:
    def __init__(self, loaded: Any) -> None:
        self._loaded = loaded

    def transcribe(
        self,
        audio_path: pathlib.Path,
        *,
        language: str,
    ) -> tuple[str, str]:
        results = self._loaded.transcribe(
            audio=str(audio_path),
            context=CONTEXT,
            language=language,
        )
        if len(results) != 1:
            raise RuntimeError(
                f"Qwen3-ASR returned {len(results)} results for one audio"
            )
        return results[0].text, results[0].language


def load_qwen_transcriber(
    *,
    model: str,
    revision: str,
    device: str,
) -> QwenTranscriber:
    import torch
    from qwen_asr import Qwen3ASRModel

    loaded = Qwen3ASRModel.from_pretrained(
        model,
        dtype=getattr(torch, DTYPE),
        device_map=device,
        max_inference_batch_size=MAX_INFERENCE_BATCH_SIZE,
        max_new_tokens=MAX_NEW_TOKENS,
        revision=revision,
    )
    return QwenTranscriber(loaded)


def run_transcription(
    *,
    audio_path: pathlib.Path,
    output_path: pathlib.Path,
    model: str,
    revision: str | None,
    device: str,
    language: str,
    load_transcriber: Callable[..., Transcriber],
    package_versions: Callable[[], dict[str, str]],
) -> dict:
    output_path.unlink(missing_ok=True)
    resolved_revision = resolve_model_revision(model, revision)
    if not audio_path.is_file():
        raise FileNotFoundError(audio_path)
    audio_seconds = wav_duration_seconds(audio_path)

    (text, detected_language), measurement = measure_load_and_inference(
        device=device,
        load=lambda: load_transcriber(
            model=model,
            revision=resolved_revision,
            device=device,
        ),
        infer=lambda transcriber: transcriber.transcribe(
            audio_path,
            language=language,
        ),
    )

    artifact = build_asr_artifact(
        engine=build_engine(
            name=ASR_ENGINE_NAME,
            model=model,
            revision=resolved_revision,
            backend=ASR_BACKEND,
            device=device,
            package_versions=package_versions(),
            inference_config=inference_config(
                device=device,
                language=language,
            ),
        ),
        runtime=build_runtime(
            device=device,
            audio_seconds=audio_seconds,
            measurement=measurement,
        ),
        text=text,
        language=detected_language,
    )
    write_json_atomic(output_path, artifact)
    return artifact


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Transcribe a WAV file with Qwen3-ASR"
    )
    parser.add_argument("audio", type=pathlib.Path)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument(
        "--revision",
        help=(
            "Pinned Hugging Face revision. The default "
            "Qwen model uses the repository-pinned revision."
        ),
    )
    parser.add_argument("--device", required=True)
    parser.add_argument("--language", required=True)
    args = parser.parse_args(argv)

    run_transcription(
        audio_path=args.audio,
        output_path=args.output,
        model=args.model,
        revision=args.revision,
        device=args.device,
        language=args.language,
        load_transcriber=load_qwen_transcriber,
        package_versions=lambda: installed_package_versions(PACKAGES),
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
