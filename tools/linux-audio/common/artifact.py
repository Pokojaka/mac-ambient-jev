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


def _validate_public_speaker(speaker: object) -> None:
    if not isinstance(speaker, dict):
        raise ValueError("speaker must be an object")
    kind = speaker.get("kind")
    index = speaker.get("index")
    if kind == "tracked":
        if (
            not isinstance(index, int)
            or isinstance(index, bool)
            or not 1 <= index <= 7
        ):
            raise ValueError(
                "speaker tracked index must be in 1...7"
            )
    elif kind in {"other", "unknown"}:
        if index is not None:
            raise ValueError(
                f"speaker {kind} must not have an index"
            )
    else:
        raise ValueError(
            "speaker kind must be tracked, other, or unknown"
        )


def validate_diarization_artifact(
    artifact: dict[str, Any],
) -> None:
    if artifact.get("schema_version") != 1:
        raise ValueError("unsupported schema_version")
    engine = artifact.get("engine")
    if not isinstance(engine, dict) or not engine.get("model"):
        raise ValueError("engine.model is required")

    policy = artifact.get("speaker_policy")
    if policy != {
        "tracked_limit": 7,
        "overflow": "other",
    }:
        raise ValueError(
            "speaker_policy must be first7-plus-other"
        )

    spans = artifact.get("spans")
    if not isinstance(spans, list):
        raise ValueError("spans must be a list")
    for span in spans:
        if not isinstance(span, dict):
            raise ValueError("span must be an object")
        start = span.get("start_ms")
        end = span.get("end_ms")
        if (
            not isinstance(start, int)
            or isinstance(start, bool)
            or not isinstance(end, int)
            or isinstance(end, bool)
            or start < 0
            or end <= start
        ):
            raise ValueError("invalid span time range")
        _validate_public_speaker(span.get("speaker"))

        confidence = span.get("confidence")
        if confidence is not None and (
            not isinstance(confidence, (int, float))
            or isinstance(confidence, bool)
            or not math.isfinite(confidence)
            or not 0 <= confidence <= 1
        ):
            raise ValueError(
                "span confidence must be finite and in 0...1"
            )

    resolver = artifact.get("overflow_resolver")
    if resolver is not None:
        if not isinstance(resolver, dict):
            raise ValueError(
                "overflow_resolver must be an object"
            )
        if not resolver.get("embedding_model"):
            raise ValueError(
                "overflow_resolver.embedding_model is required"
            )
        if not resolver.get("embedding_revision"):
            raise ValueError(
                "overflow_resolver.embedding_revision is required"
            )
        min_clean_speech_ms = resolver.get(
            "min_clean_speech_ms"
        )
        if (
            not isinstance(min_clean_speech_ms, int)
            or isinstance(min_clean_speech_ms, bool)
            or min_clean_speech_ms <= 0
        ):
            raise ValueError(
                "overflow_resolver.min_clean_speech_ms "
                "must be a positive integer"
            )
        match_threshold = resolver.get("match_threshold")
        ambiguity_margin = resolver.get("ambiguity_margin")
        if (
            not isinstance(match_threshold, (int, float))
            or isinstance(match_threshold, bool)
            or not math.isfinite(match_threshold)
            or not 0 <= match_threshold <= 1
        ):
            raise ValueError(
                "overflow_resolver.match_threshold must be in 0...1"
            )
        if (
            not isinstance(ambiguity_margin, (int, float))
            or isinstance(ambiguity_margin, bool)
            or not math.isfinite(ambiguity_margin)
            or not 0 <= ambiguity_margin <= match_threshold
        ):
            raise ValueError(
                "overflow_resolver.ambiguity_margin is invalid"
            )

    runtime = artifact.get("runtime")
    if not isinstance(runtime, dict):
        raise ValueError("runtime is required")
    for key in (
        "audio_seconds",
        "inference_seconds",
        "rtf",
    ):
        value = runtime.get(key)
        if (
            not isinstance(value, (int, float))
            or isinstance(value, bool)
            or not math.isfinite(value)
            or value < 0
        ):
            raise ValueError(
                f"runtime.{key} must be finite and non-negative"
            )


def build_diarization_artifact(
    *,
    model: str,
    revision: str | None,
    profile: str,
    backend: str,
    device: str,
    spans: list[dict[str, Any]],
    audio_seconds: float,
    inference_seconds: float,
    overflow_resolver: dict[str, Any] | None = None,
) -> dict[str, Any]:
    if audio_seconds < 0 or inference_seconds < 0:
        raise ValueError(
            "runtime durations must be non-negative"
        )
    rtf = (
        0.0
        if audio_seconds == 0
        else inference_seconds / audio_seconds
    )
    artifact = {
        "schema_version": 1,
        "engine": {
            "name": "nemotron-3-diarization",
            "model": model,
            "revision": revision,
            "profile": profile,
            "backend": backend,
            "device": device,
        },
        "speaker_policy": {
            "tracked_limit": 7,
            "overflow": "other",
        },
        "spans": spans,
        "runtime": {
            "audio_seconds": audio_seconds,
            "inference_seconds": inference_seconds,
            "rtf": rtf,
        },
    }
    if overflow_resolver is not None:
        artifact["overflow_resolver"] = overflow_resolver
    validate_diarization_artifact(artifact)
    return artifact


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
