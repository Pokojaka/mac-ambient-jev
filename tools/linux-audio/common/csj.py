"""Parser for the CSJ transcript format of the public CSJ samples.

Contract:
- A header line `NNNN start-end SPEAKER:` opens an utterance. A speech
  utterance has an empty header annotation and one or more body lines
  `surface & katakana`.
- A header annotation `<...>` (for example `<笑>` or `<雑音>`) marks a
  non-verbal utterance with no body lines. Non-verbal utterances are not
  speech: they are excluded from the speaker reference and contribute no
  reference text.
- Lines starting with `%` are comments. Blank lines are ignored.
- Surface annotations: `(F x)` filler, `(D x)` disfluent fragment, and
  `(? x)` uncertain hearing (`(?)` when nothing was heard). Tags nest.
  The verbatim reference keeps every annotated word; the content reference
  drops fillers.
- Anything else is a parser mismatch and raises ValueError.
"""

from __future__ import annotations

import re
from dataclasses import dataclass


HEADER_RE = re.compile(
    r"^\s*\d+\s+(\d+(?:\.\d+)?)-"
    r"(\d+(?:\.\d+)?)\s+([A-Za-z]+):(.*)$"
)
NONVERBAL_RE = re.compile(r"^<[^<>]+>$")
SURFACE_TAGS = {"F", "D", "?"}


@dataclass(frozen=True)
class CSJUtterance:
    start_ms: int
    end_ms: int
    speaker: str
    nonverbal: str | None
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
        if current["nonverbal"] is None and not current["surface_lines"]:
            raise ValueError(
                f"CSJ speech utterance at {current['start_ms']} ms "
                "has no surface lines"
            )
        result.append(CSJUtterance(**current))
        current = None

    for number, raw in enumerate(text.splitlines(), start=1):
        if raw.lstrip().startswith("%") or not raw.strip():
            continue
        match = HEADER_RE.match(raw)
        if match:
            flush()
            start_ms = _milliseconds(match.group(1))
            end_ms = _milliseconds(match.group(2))
            if not 0 <= start_ms < end_ms:
                raise ValueError(
                    f"invalid CSJ time range: {raw!r}"
                )
            annotation = match.group(4).strip()
            if annotation and not NONVERBAL_RE.match(annotation):
                raise ValueError(
                    f"unrecognized CSJ header annotation on line "
                    f"{number}: {annotation!r}"
                )
            current = {
                "start_ms": start_ms,
                "end_ms": end_ms,
                "speaker": match.group(3),
                "nonverbal": annotation or None,
                "surface_lines": (),
            }
            continue

        if current is None:
            raise ValueError(
                f"CSJ line {number} precedes the first utterance header"
            )
        if current["nonverbal"] is not None:
            raise ValueError(
                f"CSJ non-verbal utterance has a body on line {number}"
            )
        if "&" not in raw:
            raise ValueError(
                f"CSJ body line {number} has no '&' separator"
            )
        surface = raw.split("&", 1)[0].strip()
        if not surface:
            raise ValueError(f"CSJ body line {number} has no surface")
        _clean_surface(surface, keep_fillers=True)
        current["surface_lines"] = current["surface_lines"] + (surface,)

    flush()
    if not result:
        raise ValueError("CSJ transcript contains no utterances")
    return result


def _clean_surface(text: str, *, keep_fillers: bool) -> str:
    output, position = _parse_sequence(text, 0, keep_fillers=keep_fillers)
    if position != len(text):
        raise ValueError(f"unbalanced ')' in CSJ surface: {text!r}")
    return "".join(output.split())


def _parse_sequence(
    text: str,
    position: int,
    *,
    keep_fillers: bool,
) -> tuple[str, int]:
    output: list[str] = []
    while position < len(text) and text[position] != ")":
        if text[position] != "(":
            output.append(text[position])
            position += 1
            continue
        tag_end = position + 1
        while tag_end < len(text) and text[tag_end] not in " ()":
            tag_end += 1
        tag = text[position + 1:tag_end]
        if tag not in SURFACE_TAGS:
            raise ValueError(
                f"unrecognized CSJ annotation ({tag} in {text!r}"
            )
        content, close = _parse_sequence(
            text,
            tag_end,
            keep_fillers=keep_fillers,
        )
        if close >= len(text):
            raise ValueError(f"unclosed CSJ annotation in {text!r}")
        if tag != "F" or keep_fillers:
            output.append(content)
        position = close + 1
    return "".join(output), position


def csj_reference_text(
    utterances: list[CSJUtterance],
    *,
    keep_fillers: bool,
) -> str:
    return "".join(
        _clean_surface(line, keep_fillers=keep_fillers)
        for utterance in utterances
        for line in utterance.surface_lines
    )


def csj_speaker_reference(
    utterances: list[CSJUtterance],
) -> list[dict]:
    return [
        {
            "start_ms": utterance.start_ms,
            "end_ms": utterance.end_ms,
            "speaker_label": utterance.speaker,
        }
        for utterance in utterances
        if utterance.nonverbal is None
    ]
