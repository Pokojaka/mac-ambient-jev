from __future__ import annotations

from dataclasses import asdict, dataclass, field
import hashlib
import json
import math
import os
import pathlib
import tempfile
from typing import Any


DIARIZATION_EVALUATOR_VERSION = "diarization-eval-v1"


@dataclass(frozen=True)
class BaselineRecord:
    schema_version: int
    kind: str
    engine: str
    model: str
    revision: str | None
    backend: str
    device: str
    evaluator_version: str
    corpus: dict[str, str]
    metrics: dict[str, float]
    configuration: dict[str, Any] = field(
        default_factory=dict
    )

    def validate(self) -> None:
        if self.schema_version != 1:
            raise ValueError("unsupported schema_version")
        for name in (
            "kind",
            "engine",
            "model",
            "backend",
            "device",
            "evaluator_version",
        ):
            if not getattr(self, name):
                raise ValueError(f"{name} is required")
        if not isinstance(self.configuration, dict):
            raise ValueError(
                "configuration must be an object"
            )
        if not self.corpus:
            raise ValueError("corpus is required")
        for name, digest in self.corpus.items():
            if not name or len(digest) != 64:
                raise ValueError(
                    "corpus hashes must be SHA-256 hex strings"
                )
            try:
                int(digest, 16)
            except ValueError as exc:
                raise ValueError(
                    "corpus hashes must be SHA-256 hex strings"
                ) from exc
        if not self.metrics:
            raise ValueError("metrics is required")
        for name, value in self.metrics.items():
            if (
                not name
                or not isinstance(value, (int, float))
                or isinstance(value, bool)
                or not math.isfinite(value)
            ):
                raise ValueError(
                    "metrics must contain finite numeric values"
                )

    def write(self, path: pathlib.Path) -> None:
        self.validate()
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, temp_name = tempfile.mkstemp(
            prefix=path.name + ".",
            suffix=".tmp",
            dir=path.parent,
        )
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                json.dump(
                    asdict(self),
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


def load_baseline(path: pathlib.Path) -> BaselineRecord:
    data: dict[str, Any] = json.loads(
        path.read_text(encoding="utf-8")
    )
    required = (
        "schema_version",
        "kind",
        "engine",
        "model",
        "revision",
        "backend",
        "device",
        "evaluator_version",
        "corpus",
        "metrics",
    )
    for key in required:
        if key not in data:
            raise ValueError(f"{key} is required")
    record = BaselineRecord(
        **{key: data[key] for key in required},
        configuration=data.get("configuration", {}),
    )
    record.validate()
    return record


def compare_baseline(
    baseline: BaselineRecord,
    current: BaselineRecord,
) -> dict[str, dict[str, float]]:
    baseline.validate()
    current.validate()
    for field_name in (
        "kind",
        "engine",
        "model",
        "revision",
        "backend",
        "device",
        "evaluator_version",
        "corpus",
        "configuration",
    ):
        if getattr(baseline, field_name) != getattr(
            current,
            field_name,
        ):
            raise ValueError(
                f"{field_name} does not match baseline"
            )

    result: dict[str, dict[str, float]] = {}
    shared = sorted(
        set(baseline.metrics) & set(current.metrics)
    )
    for name in shared:
        before = baseline.metrics[name]
        after = current.metrics[name]
        result[name] = {
            "baseline": before,
            "current": after,
            "delta": after - before,
        }
    return result


def _sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(
            lambda: handle.read(1024 * 1024),
            b"",
        ):
            digest.update(chunk)
    return digest.hexdigest()


def _load_object(path: pathlib.Path, name: str) -> dict[str, Any]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError(f"{name} must be a JSON object")
    return data


def _append_numeric_metric(
    metrics: dict[str, float],
    name: str,
    source: dict[str, Any],
    key: str,
) -> None:
    value = source.get(key)
    if value is None:
        return
    if (
        not isinstance(value, (int, float))
        or isinstance(value, bool)
        or not math.isfinite(value)
    ):
        raise ValueError(
            f"{key} must be a finite numeric value"
        )
    metrics[name] = float(value)


def build_diarization_baseline_record(
    *,
    artifact_path: pathlib.Path,
    evaluation_path: pathlib.Path,
    audio_path: pathlib.Path,
    speaker_reference_path: pathlib.Path,
) -> BaselineRecord:
    artifact = _load_object(
        artifact_path,
        "diarization artifact",
    )
    evaluation = _load_object(
        evaluation_path,
        "diarization evaluation",
    )
    if artifact.get("schema_version") != 1:
        raise ValueError(
            "unsupported diarization artifact schema_version"
        )

    engine = artifact.get("engine")
    runtime = artifact.get("runtime")
    collapsed = evaluation.get("collapsed")
    standard = evaluation.get("standard")
    if not isinstance(engine, dict):
        raise ValueError("artifact engine is required")
    if not isinstance(runtime, dict):
        raise ValueError("artifact runtime is required")
    if not isinstance(collapsed, dict):
        raise ValueError(
            "collapsed diarization evaluation is required"
        )
    if standard is not None and not isinstance(
        standard,
        dict,
    ):
        raise ValueError(
            "standard diarization evaluation must be an object"
        )

    metrics: dict[str, float] = {}
    if isinstance(standard, dict):
        for output_name, key in (
            ("standard_der", "der"),
            ("standard_miss_ms", "miss_ms"),
            ("standard_false_alarm_ms", "false_alarm_ms"),
            ("standard_confusion_ms", "confusion_ms"),
            ("standard_overlap_recall", "overlap_recall"),
            (
                "speaker_switch_boundary_mae_ms",
                "speaker_switch_boundary_mae_ms",
            ),
        ):
            _append_numeric_metric(
                metrics,
                output_name,
                standard,
                key,
            )

    for output_name, key in (
        ("collapsed_der", "der"),
        (
            "tracked_speaker_confusion_ms",
            "tracked_speaker_confusion_ms",
        ),
        ("other_precision", "other_precision"),
        ("other_recall", "other_recall"),
        (
            "other_to_tracked_leakage_ms",
            "other_to_tracked_leakage_ms",
        ),
        (
            "tracked_to_other_leakage_ms",
            "tracked_to_other_leakage_ms",
        ),
        ("unknown_rate", "unknown_rate"),
        (
            "overflow_detection_recall",
            "overflow_detection_recall",
        ),
        ("collapsed_overlap_recall", "overlap_recall"),
    ):
        _append_numeric_metric(
            metrics,
            output_name,
            collapsed,
            key,
        )

    _append_numeric_metric(
        metrics,
        "rtf",
        runtime,
        "rtf",
    )
    _append_numeric_metric(
        metrics,
        "peak_vram_mb",
        runtime,
        "peak_vram_mb",
    )

    if "collapsed_der" not in metrics:
        raise ValueError("collapsed der is required")

    model = engine.get("model")
    revision = engine.get("revision")
    backend = engine.get("backend")
    device = engine.get("device")
    engine_name = engine.get("name")
    for name, value in (
        ("engine.name", engine_name),
        ("engine.model", model),
        ("engine.revision", revision),
        ("engine.backend", backend),
        ("engine.device", device),
    ):
        if not isinstance(value, str) or not value:
            raise ValueError(f"{name} is required")

    configuration: dict[str, Any] = {}
    profile = engine.get("profile")
    if profile is not None:
        configuration["profile"] = profile
    resolver = artifact.get("overflow_resolver")
    if resolver is not None:
        if not isinstance(resolver, dict):
            raise ValueError(
                "overflow_resolver must be an object"
            )
        configuration["overflow_resolver"] = resolver

    record = BaselineRecord(
        schema_version=1,
        kind="diarization",
        engine=engine_name,
        model=model,
        revision=revision,
        backend=backend,
        device=device,
        evaluator_version=
            DIARIZATION_EVALUATOR_VERSION,
        corpus={
            "audio": _sha256_file(audio_path),
            "speaker_reference": _sha256_file(
                speaker_reference_path
            ),
        },
        metrics=metrics,
        configuration=configuration,
    )
    record.validate()
    return record
