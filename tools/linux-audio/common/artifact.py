from __future__ import annotations

import importlib.metadata
import math
from collections.abc import Iterable
from typing import Any

from common.runtime_metrics import RuntimeMeasurement, is_cuda_device


SCHEMA_VERSION = 2
ASR_ENGINE_NAME = "qwen3-asr"
ASR_BACKEND = "transformers"
DIARIZATION_ENGINE_NAME = "nemotron-3-diarization"
DIARIZATION_BACKEND = "nemo"
SPEAKER_POLICY = {"tracked_limit": 7, "overflow": "other"}

ENGINE_KEYS = {
    "name",
    "model",
    "revision",
    "backend",
    "device",
    "package_versions",
    "inference_config",
}
CUDA_RUNTIME_KEYS = {"resident_vram_mb", "peak_vram_mb"}
BASE_RUNTIME_KEYS = {
    "audio_seconds",
    "model_load_seconds",
    "inference_seconds",
    "rtf",
}
ASR_SEGMENT_KEYS = {"start_ms", "end_ms", "text", "language"}
OVERFLOW_RESOLVER_KEYS = {
    "embedding_model",
    "embedding_revision",
    "match_threshold",
    "ambiguity_margin",
    "min_clean_speech_ms",
}


def installed_package_versions(names: Iterable[str]) -> dict[str, str]:
    return {
        name: importlib.metadata.version(name)
        for name in names
    }


def _is_number(value: object) -> bool:
    return (
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and math.isfinite(value)
    )


def _is_int(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _require_keys(value: dict, expected: set[str], name: str) -> None:
    if set(value) != expected:
        raise ValueError(
            f"{name} keys must be {sorted(expected)}, "
            f"got {sorted(value)}"
        )


def _require_object(value: object, name: str) -> dict:
    if not isinstance(value, dict):
        raise ValueError(f"{name} must be an object")
    return value


def _require_text(value: object, name: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{name} must be a non-empty string")
    return value


def build_engine(
    *,
    name: str,
    model: str,
    revision: str,
    backend: str,
    device: str,
    package_versions: dict[str, str],
    inference_config: dict[str, Any],
) -> dict[str, Any]:
    return {
        "name": name,
        "model": model,
        "revision": revision,
        "backend": backend,
        "device": device,
        "package_versions": package_versions,
        "inference_config": inference_config,
    }


def build_runtime(
    *,
    device: str,
    audio_seconds: float,
    measurement: RuntimeMeasurement,
) -> dict[str, float]:
    if audio_seconds <= 0:
        raise ValueError("audio_seconds must be positive")
    runtime = {
        "audio_seconds": audio_seconds,
        "model_load_seconds": measurement.model_load_seconds,
        "inference_seconds": measurement.inference_seconds,
        "rtf": measurement.inference_seconds / audio_seconds,
    }
    if is_cuda_device(device):
        if (
            measurement.resident_vram_mb is None
            or measurement.peak_vram_mb is None
        ):
            raise ValueError(
                f"device {device!r} requires measured resident and "
                "peak VRAM"
            )
        runtime["resident_vram_mb"] = measurement.resident_vram_mb
        runtime["peak_vram_mb"] = measurement.peak_vram_mb
    elif (
        measurement.resident_vram_mb is not None
        or measurement.peak_vram_mb is not None
    ):
        raise ValueError("VRAM is not measured on cpu")
    return runtime


def validate_engine(
    engine: object,
    *,
    name: str,
    backend: str,
) -> dict:
    engine = _require_object(engine, "engine")
    _require_keys(engine, ENGINE_KEYS, "engine")
    if engine["name"] != name:
        raise ValueError(f"engine.name must be {name!r}")
    if engine["backend"] != backend:
        raise ValueError(f"engine.backend must be {backend!r}")
    for key in ("model", "revision", "device"):
        _require_text(engine[key], f"engine.{key}")
    is_cuda_device(engine["device"])

    package_versions = _require_object(
        engine["package_versions"],
        "engine.package_versions",
    )
    if not package_versions:
        raise ValueError("engine.package_versions must not be empty")
    for package, version in package_versions.items():
        _require_text(package, "engine.package_versions key")
        _require_text(version, f"engine.package_versions.{package}")

    inference_config = _require_object(
        engine["inference_config"],
        "engine.inference_config",
    )
    if not inference_config:
        raise ValueError("engine.inference_config must not be empty")
    return engine


def _validate_runtime(runtime: object, *, device: str) -> dict:
    runtime = _require_object(runtime, "runtime")
    cuda = is_cuda_device(device)
    expected = BASE_RUNTIME_KEYS | (CUDA_RUNTIME_KEYS if cuda else set())
    _require_keys(runtime, expected, "runtime")
    for key in expected:
        value = runtime[key]
        if not _is_number(value) or value < 0:
            raise ValueError(
                f"runtime.{key} must be finite and non-negative"
            )
    if runtime["audio_seconds"] == 0:
        raise ValueError("runtime.audio_seconds must be positive")
    expected_rtf = runtime["inference_seconds"] / runtime["audio_seconds"]
    if not math.isclose(runtime["rtf"], expected_rtf, rel_tol=1e-9):
        raise ValueError(
            "runtime.rtf must equal inference_seconds / audio_seconds"
        )
    return runtime


def build_asr_artifact(
    *,
    engine: dict[str, Any],
    runtime: dict[str, float],
    text: str,
    language: str,
) -> dict[str, Any]:
    artifact = {
        "schema_version": SCHEMA_VERSION,
        "engine": engine,
        "segments": [{
            "start_ms": 0,
            "end_ms": round(runtime["audio_seconds"] * 1000),
            "text": text,
            "language": language,
        }],
        "runtime": runtime,
    }
    validate_asr_artifact(artifact)
    return artifact


def validate_asr_artifact(artifact: dict[str, Any]) -> None:
    """The ASR artifact carries one segment spanning the whole audio.

    The segment is the envelope for CER, not a timing claim.
    """
    if artifact.get("schema_version") != SCHEMA_VERSION:
        raise ValueError("unsupported schema_version")
    _require_keys(
        artifact,
        {"schema_version", "engine", "segments", "runtime"},
        "ASR artifact",
    )
    engine = validate_engine(
        artifact["engine"],
        name=ASR_ENGINE_NAME,
        backend=ASR_BACKEND,
    )
    runtime = _validate_runtime(
        artifact["runtime"],
        device=engine["device"],
    )

    segments = artifact["segments"]
    if not isinstance(segments, list) or len(segments) != 1:
        raise ValueError(
            "segments must hold exactly one whole-audio segment"
        )
    segment = _require_object(segments[0], "segment")
    _require_keys(segment, ASR_SEGMENT_KEYS, "segment")
    if segment["start_ms"] != 0 or not _is_int(segment["start_ms"]):
        raise ValueError("segment.start_ms must be 0")
    expected_end = round(runtime["audio_seconds"] * 1000)
    if (
        not _is_int(segment["end_ms"])
        or segment["end_ms"] != expected_end
    ):
        raise ValueError(
            "segment.end_ms must equal the audio duration in ms"
        )
    if not isinstance(segment["text"], str):
        raise ValueError("segment.text must be a string")
    if not isinstance(segment["language"], str):
        raise ValueError("segment.language must be a string")


def _validate_time_range(span: dict, name: str) -> None:
    start = span.get("start_ms")
    end = span.get("end_ms")
    if (
        not _is_int(start)
        or not _is_int(end)
        or start < 0
        or end <= start
    ):
        raise ValueError(f"invalid {name} time range")


def _validate_public_speaker(speaker: object) -> None:
    speaker = _require_object(speaker, "speaker")
    kind = speaker.get("kind")
    if kind == "tracked":
        _require_keys(speaker, {"kind", "index"}, "tracked speaker")
        index = speaker["index"]
        if not _is_int(index) or not 1 <= index <= 7:
            raise ValueError("speaker tracked index must be in 1...7")
    elif kind in {"other", "unknown"}:
        _require_keys(speaker, {"kind"}, f"{kind} speaker")
    else:
        raise ValueError(
            "speaker kind must be tracked, other, or unknown"
        )


def _validate_overflow_resolver(resolver: object) -> None:
    resolver = _require_object(resolver, "overflow_resolver")
    _require_keys(resolver, OVERFLOW_RESOLVER_KEYS, "overflow_resolver")
    _require_text(
        resolver["embedding_model"],
        "overflow_resolver.embedding_model",
    )
    _require_text(
        resolver["embedding_revision"],
        "overflow_resolver.embedding_revision",
    )
    min_clean_speech_ms = resolver["min_clean_speech_ms"]
    if not _is_int(min_clean_speech_ms) or min_clean_speech_ms <= 0:
        raise ValueError(
            "overflow_resolver.min_clean_speech_ms "
            "must be a positive integer"
        )
    match_threshold = resolver["match_threshold"]
    ambiguity_margin = resolver["ambiguity_margin"]
    if not _is_number(match_threshold) or not 0 <= match_threshold <= 1:
        raise ValueError(
            "overflow_resolver.match_threshold must be in 0...1"
        )
    if (
        not _is_number(ambiguity_margin)
        or not 0 <= ambiguity_margin <= match_threshold
    ):
        raise ValueError("overflow_resolver.ambiguity_margin is invalid")


def build_diarization_artifact(
    *,
    engine: dict[str, Any],
    runtime: dict[str, float],
    spans: list[dict[str, Any]],
    raw_spans: list[dict[str, Any]],
    overflow_resolver: dict[str, Any],
) -> dict[str, Any]:
    artifact = {
        "schema_version": SCHEMA_VERSION,
        "engine": engine,
        "speaker_policy": dict(SPEAKER_POLICY),
        "spans": spans,
        "raw_spans": raw_spans,
        "overflow_resolver": overflow_resolver,
        "runtime": runtime,
    }
    validate_diarization_artifact(artifact)
    return artifact


def validate_diarization_artifact(artifact: dict[str, Any]) -> None:
    if artifact.get("schema_version") != SCHEMA_VERSION:
        raise ValueError("unsupported schema_version")
    _require_keys(
        artifact,
        {
            "schema_version",
            "engine",
            "speaker_policy",
            "spans",
            "raw_spans",
            "overflow_resolver",
            "runtime",
        },
        "diarization artifact",
    )
    engine = validate_engine(
        artifact["engine"],
        name=DIARIZATION_ENGINE_NAME,
        backend=DIARIZATION_BACKEND,
    )
    if artifact["speaker_policy"] != SPEAKER_POLICY:
        raise ValueError("speaker_policy must be first7-plus-other")

    spans = artifact["spans"]
    if not isinstance(spans, list):
        raise ValueError("spans must be a list")
    for span in spans:
        span = _require_object(span, "span")
        _require_keys(span, {"start_ms", "end_ms", "speaker"}, "span")
        _validate_time_range(span, "span")
        _validate_public_speaker(span["speaker"])

    raw_spans = artifact["raw_spans"]
    if not isinstance(raw_spans, list):
        raise ValueError("raw_spans must be a list")
    for raw_span in raw_spans:
        raw_span = _require_object(raw_span, "raw span")
        _require_keys(
            raw_span,
            {"start_ms", "end_ms", "speaker_label"},
            "raw span",
        )
        _validate_time_range(raw_span, "raw span")
        _require_text(raw_span["speaker_label"], "raw span speaker_label")

    _validate_overflow_resolver(artifact["overflow_resolver"])
    _validate_runtime(artifact["runtime"], device=engine["device"])
