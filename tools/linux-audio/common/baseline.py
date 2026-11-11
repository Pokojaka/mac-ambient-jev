from __future__ import annotations

import json
import math
import pathlib
from dataclasses import asdict, dataclass, fields
from typing import Any

from common.artifact import (
    ASR_BACKEND,
    ASR_ENGINE_NAME,
    validate_asr_artifact,
    validate_engine,
)
from common.files import sha256_file, write_json_atomic
from common.runtime_metrics import is_cuda_device


SCHEMA_VERSION = 2
REFERENCE_KINDS = ("verbatim", "content")

ENGINES = (ASR_ENGINE_NAME, ASR_BACKEND)
CONDITION_KEYS = {"reference_kind", "normalizer_version"}
CORPUS_KEYS = {"audio", "reference"}
RUNTIME_METRICS = {"rtf": "rtf", "model_load_seconds": "model_load_seconds"}
CUDA_RUNTIME_METRICS = {
    "resident_vram_mb": "resident_vram_mb",
    "peak_vram_mb": "peak_vram_mb",
}
ASR_EVALUATION_METRICS = {
    "raw_cer": ("raw", "rate"),
    "normalized_cer": ("normalized", "rate"),
}


def expected_metric_names(device: str) -> set[str]:
    names = set(ASR_EVALUATION_METRICS) | set(RUNTIME_METRICS)
    if is_cuda_device(device):
        names |= set(CUDA_RUNTIME_METRICS)
    return names


def _require_sha256(value: object, name: str) -> None:
    if (
        not isinstance(value, str)
        or len(value) != 64
        or any(character not in "0123456789abcdef" for character in value)
    ):
        raise ValueError(f"{name} must be a lowercase SHA-256 hex string")


@dataclass(frozen=True)
class BaselineRecord:
    """A metric set plus every condition needed to reproduce it."""

    schema_version: int
    engine: dict[str, Any]
    conditions: dict[str, Any]
    corpus: dict[str, str]
    metrics: dict[str, float]

    def validate(self) -> None:
        if self.schema_version != SCHEMA_VERSION:
            raise ValueError("unsupported schema_version")
        engine_name, backend = ENGINES
        validate_engine(self.engine, name=engine_name, backend=backend)

        if set(self.conditions) != CONDITION_KEYS:
            raise ValueError(
                f"conditions keys must be "
                f"{sorted(CONDITION_KEYS)}"
            )
        if self.conditions["reference_kind"] not in REFERENCE_KINDS:
            raise ValueError(
                f"reference_kind must be one of {REFERENCE_KINDS}"
            )
        version = self.conditions["normalizer_version"]
        if not isinstance(version, str) or not version:
            raise ValueError("normalizer_version is required")

        if set(self.corpus) != CORPUS_KEYS:
            raise ValueError(
                f"corpus keys must be {sorted(CORPUS_KEYS)}"
            )
        for name, digest in self.corpus.items():
            _require_sha256(digest, f"corpus.{name}")

        expected = expected_metric_names(self.engine["device"])
        if set(self.metrics) != expected:
            raise ValueError(
                f"metrics must be exactly {sorted(expected)}, "
                f"got {sorted(self.metrics)}"
            )
        for name, value in self.metrics.items():
            if (
                not isinstance(value, (int, float))
                or isinstance(value, bool)
                or not math.isfinite(value)
            ):
                raise ValueError(
                    f"metric {name} must be a finite number"
                )

    def write(self, path: pathlib.Path) -> None:
        self.validate()
        write_json_atomic(path, asdict(self))


def load_baseline(path: pathlib.Path) -> BaselineRecord:
    data = json.loads(path.read_text(encoding="utf-8"))
    expected = {field.name for field in fields(BaselineRecord)}
    if not isinstance(data, dict) or set(data) != expected:
        raise ValueError(
            f"baseline keys must be {sorted(expected)}"
        )
    record = BaselineRecord(**data)
    record.validate()
    return record


def compare_baseline(
    baseline: BaselineRecord,
    current: BaselineRecord,
) -> dict[str, dict[str, float]]:
    baseline.validate()
    current.validate()
    for field_name in ("engine", "conditions", "corpus"):
        if getattr(baseline, field_name) != getattr(current, field_name):
            raise ValueError(
                f"{field_name} does not match baseline"
            )
    if set(baseline.metrics) != set(current.metrics):
        raise ValueError("metric set does not match baseline")

    result: dict[str, dict[str, float]] = {}
    for name in sorted(baseline.metrics):
        before = baseline.metrics[name]
        after = current.metrics[name]
        result[name] = {
            "baseline": before,
            "current": after,
            "delta": after - before,
        }
    return result


def _load_object(path: pathlib.Path, name: str) -> dict[str, Any]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError(f"{name} must be a JSON object")
    return data


def _collect_metrics(
    sources: dict[str, Any],
    mapping: dict[str, tuple[str, str]],
) -> dict[str, Any]:
    metrics: dict[str, Any] = {}
    for name, (section, key) in mapping.items():
        source = sources[section]
        if not isinstance(source, dict) or key not in source:
            raise ValueError(f"{section}.{key} is required")
        metrics[name] = source[key]
    return metrics


def _runtime_metrics(artifact: dict[str, Any]) -> dict[str, Any]:
    runtime = artifact["runtime"]
    mapping = dict(RUNTIME_METRICS)
    if is_cuda_device(artifact["engine"]["device"]):
        mapping |= CUDA_RUNTIME_METRICS
    return {name: runtime[key] for name, key in mapping.items()}


def build_asr_baseline_record(
    *,
    artifact_path: pathlib.Path,
    evaluation_path: pathlib.Path,
    audio_path: pathlib.Path,
    reference_path: pathlib.Path,
    reference_kind: str,
) -> BaselineRecord:
    artifact = _load_object(artifact_path, "ASR artifact")
    validate_asr_artifact(artifact)
    evaluation = _load_object(evaluation_path, "ASR evaluation")

    record = BaselineRecord(
        schema_version=SCHEMA_VERSION,
        engine=artifact["engine"],
        conditions={
            "reference_kind": reference_kind,
            "normalizer_version": evaluation.get("normalizer_version"),
        },
        corpus={
            "audio": sha256_file(audio_path),
            "reference": sha256_file(reference_path),
        },
        metrics=_collect_metrics(evaluation, ASR_EVALUATION_METRICS)
        | _runtime_metrics(artifact),
    )
    record.validate()
    return record
