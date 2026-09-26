from __future__ import annotations

import json
import math
import os
import pathlib
import tempfile
from typing import Any


def build_asr_artifact(
    *,
    model: str,
    revision: str | None,
    backend: str,
    device: str,
    text: str,
    language: str | None,
    audio_seconds: float,
    inference_seconds: float,
) -> dict[str, Any]:
    if audio_seconds < 0 or inference_seconds < 0:
        raise ValueError("runtime durations must be non-negative")
    rtf = 0.0 if audio_seconds == 0 else inference_seconds / audio_seconds
    artifact = {
        "schema_version": 1,
        "engine": {
            "name": "qwen3-asr",
            "model": model,
            "revision": revision,
            "backend": backend,
            "device": device,
        },
        "segments": [{
            "start_ms": 0,
            "end_ms": int(round(audio_seconds * 1000)),
            "text": text,
            "language": language,
        }],
        "runtime": {
            "audio_seconds": audio_seconds,
            "inference_seconds": inference_seconds,
            "rtf": rtf,
        },
    }
    validate_asr_artifact(artifact)
    return artifact


def validate_asr_artifact(artifact: dict[str, Any]) -> None:
    if artifact.get("schema_version") != 1:
        raise ValueError("unsupported schema_version")
    engine = artifact.get("engine")
    if not isinstance(engine, dict) or not engine.get("model"):
        raise ValueError("engine.model is required")
    segments = artifact.get("segments")
    if not isinstance(segments, list) or not segments:
        raise ValueError("segments must be a non-empty list")
    runtime = artifact.get("runtime")
    if not isinstance(runtime, dict):
        raise ValueError("runtime is required")
    for key in ("audio_seconds", "inference_seconds", "rtf"):
        value = runtime.get(key)
        if not isinstance(value, (int, float)) or not math.isfinite(value):
            raise ValueError(f"runtime.{key} must be finite")
        if value < 0:
            raise ValueError(f"runtime.{key} must be non-negative")


def write_json_atomic(path: pathlib.Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(
        prefix=path.name + ".",
        suffix=".tmp",
        dir=path.parent,
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(
                payload,
                handle,
                ensure_ascii=False,
                indent=2,
                sort_keys=True,
            )
            handle.write("\n")
        os.replace(temp_name, path)
    except Exception:
        try:
            os.unlink(temp_name)
        except FileNotFoundError:
            pass
        raise
