from __future__ import annotations

import math
from collections.abc import Sequence


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

        if len(self.references) < 7:
            self.references.append(vector)
            return {
                "kind": "tracked",
                "index": len(self.references),
            }

        if score >= self.match_threshold - self.ambiguity_margin:
            return {"kind": "unknown"}
        return {"kind": "other"}



def resolve_spans_with_embeddings(
    spans: list[dict],
    *,
    embedding_for_span,
    resolver: SpeakerOverflowResolver,
) -> list[dict]:
    ordered = sorted(
        enumerate(spans),
        key=lambda item: (
            item[1]["start_ms"],
            item[0],
        ),
    )

    result: list[dict] = []
    for _, span in ordered:
        result.append({
            "start_ms": span["start_ms"],
            "end_ms": span["end_ms"],
            "speaker": resolver.resolve(
                embedding_for_span(span)
            ),
        })
    return result
