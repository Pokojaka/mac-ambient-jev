from __future__ import annotations

from dataclasses import dataclass
import re


HEADER_RE = re.compile(
    r"^\s*\d+\s+(\d+(?:\.\d+)?)-"
    r"(\d+(?:\.\d+)?)\s+([A-Za-z]+):(.*)$"
)


@dataclass(frozen=True)
class CSJUtterance:
    start_ms: int
    end_ms: int
    speaker: str
    header_annotation: str
    surface_lines: tuple[str, ...]


def _milliseconds(value: str) -> int:
    return int(round(float(value) * 1000))


def parse_csj_transcript(text: str) -> list[CSJUtterance]:
    result: list[CSJUtterance] = []
    current: dict | None = None

    def flush() -> None:
        nonlocal current
        if current is None:
            return
        result.append(CSJUtterance(**current))
        current = None

    for raw in text.splitlines():
        match = HEADER_RE.match(raw)
        if match:
            flush()
            start_ms = _milliseconds(match.group(1))
            end_ms = _milliseconds(match.group(2))
            if not 0 <= start_ms < end_ms:
                raise ValueError(
                    f"invalid CSJ time range: {raw!r}"
                )
            current = {
                "start_ms": start_ms,
                "end_ms": end_ms,
                "speaker": match.group(3),
                "header_annotation":
                    match.group(4).strip(),
                "surface_lines": (),
            }
            continue

        if current is None:
            continue
        if raw.lstrip().startswith("%"):
            continue

        surface = raw.split("&", 1)[0].strip()
        if not surface:
            continue
        current["surface_lines"] = (
            current["surface_lines"] + (surface,)
        )

    flush()
    return result
