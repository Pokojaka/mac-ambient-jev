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


ANGLE_TAG_RE = re.compile(r"<[^>]*>")
LAUGH_RE = re.compile(r"\(笑[^)]*\)")
FILLER_RE = re.compile(r"\(F\s*([^()]*)\)")
UNCERTAIN_RE = re.compile(r"\(\?\s*([^()]*)\)")
DISFLUENCY_RE = re.compile(r"\(D\s*([^()]*)\)")
GENERIC_PAREN_RE = re.compile(r"\([^()]*\)")


def _clean_surface(
    text: str,
    *,
    keep_fillers: bool,
) -> str:
    value = ANGLE_TAG_RE.sub("", text)
    value = LAUGH_RE.sub("", value)
    previous = None
    while value != previous:
        previous = value
        value = UNCERTAIN_RE.sub(
            lambda match: match.group(1),
            value,
        )
        value = DISFLUENCY_RE.sub(
            lambda match: match.group(1),
            value,
        )
        value = FILLER_RE.sub(
            (
                lambda match: match.group(1)
            )
            if keep_fillers
            else (lambda match: ""),
            value,
        )
    value = GENERIC_PAREN_RE.sub("", value)
    return "".join(value.split())


def csj_reference_text(
    utterances: list[CSJUtterance],
    *,
    keep_fillers: bool,
) -> str:
    parts: list[str] = []
    for utterance in utterances:
        for line in utterance.surface_lines:
            cleaned = _clean_surface(
                line,
                keep_fillers=keep_fillers,
            )
            if cleaned:
                parts.append(cleaned)
    return "".join(parts)
