from __future__ import annotations

import math
from collections.abc import Callable, Sequence


TRACKED_LIMIT = 7


def cosine_similarity(
    left: Sequence[float],
    right: Sequence[float],
) -> float:
    if len(left) != len(right) or not left:
        raise ValueError("embeddings must have equal non-zero dimensions")
    dot = sum(a * b for a, b in zip(left, right))
    left_norm = math.sqrt(sum(value * value for value in left))
    right_norm = math.sqrt(sum(value * value for value in right))
    if left_norm == 0 or right_norm == 0:
        raise ValueError("embedding norm must be non-zero")
    return dot / (left_norm * right_norm)


class SpeakerOverflowResolver:
    """Maps embeddings to Speaker 1...7, OTHER, or UNKNOWN.

    A best score in [threshold - margin, threshold) is ambiguous and stays
    UNKNOWN regardless of how many speakers are registered. Only a score
    below threshold - margin opens a new slot, or OTHER once seven exist.
    """

    def __init__(
        self,
        *,
        match_threshold: float,
        ambiguity_margin: float,
    ) -> None:
        if not 0 <= ambiguity_margin <= match_threshold <= 1:
            raise ValueError("invalid thresholds")
        self.match_threshold = match_threshold
        self.ambiguity_margin = ambiguity_margin
        self.references: list[list[float]] = []

    def resolve(self, embedding: Sequence[float]) -> dict:
        vector = list(embedding)
        if not self.references:
            self.references.append(vector)
            return {"kind": "tracked", "index": 1}

        scores = [
            cosine_similarity(vector, reference)
            for reference in self.references
        ]
        best = max(range(len(scores)), key=scores.__getitem__)
        score = scores[best]

        if score >= self.match_threshold:
            return {"kind": "tracked", "index": best + 1}
        if score >= self.match_threshold - self.ambiguity_margin:
            return {"kind": "unknown"}
        if len(self.references) < TRACKED_LIMIT:
            self.references.append(vector)
            return {
                "kind": "tracked",
                "index": len(self.references),
            }
        return {"kind": "other"}


def first_clean_subspan(
    span: dict,
    all_spans: list[dict],
    *,
    min_clean_speech_ms: int,
) -> tuple[int, int] | None:
    """Returns the earliest part of span that is clean speech.

    A clean part is a contiguous stretch that no other speaker label
    overlaps and that lasts at least min_clean_speech_ms. The Swift
    reference collapse applies the same rule.
    """
    if min_clean_speech_ms <= 0:
        raise ValueError("min_clean_speech_ms must be positive")
    start = span["start_ms"]
    end = span["end_ms"]
    blocked = sorted(
        (max(other["start_ms"], start), min(other["end_ms"], end))
        for other in all_spans
        if other["speaker_label"] != span["speaker_label"]
        and other["start_ms"] < end
        and other["end_ms"] > start
    )

    cursor = start
    for blocked_start, blocked_end in blocked + [(end, end)]:
        if blocked_start - cursor >= min_clean_speech_ms:
            return cursor, blocked_start
        cursor = max(cursor, blocked_end)
    return None


def resolve_spans_with_embeddings(
    spans: list[dict],
    *,
    embedding_for_span: Callable[[dict], list[float]],
    resolver: SpeakerOverflowResolver,
    min_clean_speech_ms: int,
) -> list[dict]:
    """Resolves spans in order of their first clean speech.

    A span without enough clean speech stays UNKNOWN and never registers a
    speaker, so arrival order follows the first sufficient clean utterance.
    """
    clean = [
        first_clean_subspan(
            span,
            spans,
            min_clean_speech_ms=min_clean_speech_ms,
        )
        for span in spans
    ]
    speakers: list[dict] = [{"kind": "unknown"} for _ in spans]
    resolution_order = sorted(
        (index for index, subspan in enumerate(clean) if subspan),
        key=lambda index: (clean[index][0], index),
    )
    for index in resolution_order:
        clean_start, clean_end = clean[index]
        speakers[index] = resolver.resolve(
            embedding_for_span({
                "start_ms": clean_start,
                "end_ms": clean_end,
            })
        )

    output_order = sorted(
        range(len(spans)),
        key=lambda index: (spans[index]["start_ms"], index),
    )
    return [
        {
            "start_ms": spans[index]["start_ms"],
            "end_ms": spans[index]["end_ms"],
            "speaker": speakers[index],
        }
        for index in output_order
    ]
