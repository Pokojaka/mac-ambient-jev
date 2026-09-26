from __future__ import annotations

import argparse
import pathlib
import time
import wave
from collections.abc import Callable

from common.artifact import build_asr_artifact, write_json_atomic
from common.runtime_metrics import (
    begin_cuda_measurement,
    end_cuda_measurement,
)

DEFAULT_MODEL = "Qwen/Qwen3-ASR-1.7B"
DEFAULT_MODEL_REVISION = (
    "7278e1e70fe206f11671096ffdd38061171dd6e5"
)


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


def wav_duration_seconds(path: pathlib.Path) -> float:
    try:
        with wave.open(str(path), "rb") as wav:
            rate = wav.getframerate()
            if rate <= 0:
                raise ValueError("invalid WAV sample rate")
            return wav.getnframes() / rate
    except wave.Error as exc:
        raise ValueError(
            "duration probing currently requires WAV input"
        ) from exc


def make_qwen_transcriber(
    *,
    model: str,
    revision: str | None,
    device: str,
    language: str | None,
) -> Callable[[pathlib.Path], tuple[str, str | None]]:
    import torch
    from qwen_asr import Qwen3ASRModel

    resolved_revision = resolve_model_revision(
        model,
        revision,
    )
    kwargs = {
        "dtype": torch.bfloat16,
        "device_map": device,
        "max_inference_batch_size": 1,
        "max_new_tokens": 4096,
        "revision": resolved_revision,
    }

    loaded = Qwen3ASRModel.from_pretrained(model, **kwargs)

    def transcribe(path: pathlib.Path) -> tuple[str, str | None]:
        results = loaded.transcribe(
            audio=str(path),
            language=language,
        )
        if not results:
            raise RuntimeError("Qwen3-ASR returned no result")
        result = results[0]
        return result.text, getattr(result, "language", None)

    return transcribe


def run_transcription(
    *,
    audio_path: pathlib.Path,
    output_path: pathlib.Path,
    model: str,
    revision: str | None,
    device: str,
    transcribe: Callable[[pathlib.Path], tuple[str, str | None]],
) -> dict:
    if not audio_path.is_file():
        raise FileNotFoundError(audio_path)

    output_path.unlink(missing_ok=True)
    audio_seconds = wav_duration_seconds(audio_path)
    measurement = begin_cuda_measurement(device)
    started = time.perf_counter()
    text, language = transcribe(audio_path)
    peak_vram_mb = end_cuda_measurement(
        device,
        measurement,
    )
    inference_seconds = time.perf_counter() - started

    artifact = build_asr_artifact(
        model=model,
        revision=revision,
        backend="transformers",
        device=device,
        text=text,
        language=language,
        audio_seconds=audio_seconds,
        inference_seconds=inference_seconds,
        peak_vram_mb=peak_vram_mb,
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
    parser.add_argument("--device", default="cuda:0")
    parser.add_argument("--language", default="Japanese")
    args = parser.parse_args(argv)

    revision = resolve_model_revision(
        args.model,
        args.revision,
    )
    transcribe = make_qwen_transcriber(
        model=args.model,
        revision=revision,
        device=args.device,
        language=args.language,
    )
    run_transcription(
        audio_path=args.audio,
        output_path=args.output,
        model=args.model,
        revision=revision,
        device=args.device,
        transcribe=transcribe,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
