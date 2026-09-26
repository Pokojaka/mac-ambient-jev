from __future__ import annotations

from dataclasses import asdict, dataclass
import json
import os
import pathlib
import tempfile
from typing import Any


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
        **{key: data[key] for key in required}
    )
    record.validate()
    return record


def compare_baseline(
    baseline: BaselineRecord,
    current: BaselineRecord,
) -> dict[str, dict[str, float]]:
    baseline.validate()
    current.validate()
    for field in (
        "kind",
        "engine",
        "model",
        "revision",
        "backend",
        "device",
        "evaluator_version",
        "corpus",
    ):
        if getattr(baseline, field) != getattr(current, field):
            raise ValueError(
                f"{field} does not match baseline"
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
