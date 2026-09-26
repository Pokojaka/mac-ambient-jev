from __future__ import annotations

import json
import pathlib
import wave
from collections.abc import Callable

from common.audio import normalize_to_wav
from common.pcm_mix import mix


SynthesizeFn = Callable[
    [str, int, pathlib.Path],
    None,
]


def _duration_ms(path: pathlib.Path) -> int:
    with wave.open(str(path), "rb") as wav:
        return round(
            wav.getnframes()
            * 1000
            / wav.getframerate()
        )


def generate_scenario(
    manifest: dict,
    *,
    scenario_id: str,
    speaker_ids: list[int],
    output_root: pathlib.Path,
    synthesize: SynthesizeFn,
) -> dict:
    scenario = next(
        (
            item
            for item in manifest.get(
                "diarization_scenarios",
                [],
            )
            if item.get("id") == scenario_id
        ),
        None,
    )
    if scenario is None:
        raise ValueError(
            f"unknown scenario: {scenario_id}"
        )

    speaker_count = int(
        scenario["speaker_count"]
    )
    if len(speaker_ids) < speaker_count:
        raise ValueError(
            f"{speaker_count} distinct speaker IDs "
            "are required"
        )

    selected = speaker_ids[:speaker_count]
    if len(set(selected)) != len(selected):
        raise ValueError(
            "speaker IDs must be unique"
        )

    utterances = manifest.get("utterances") or []
    if not utterances:
        raise ValueError("utterances are required")

    overlap_ratio = float(
        scenario.get("overlap_ratio", 0.0)
    )
    if not 0 <= overlap_ratio < 1:
        raise ValueError(
            "overlap_ratio must be in [0, 1)"
        )

    scenario_dir = output_root / scenario_id
    raw_dir = scenario_dir / "raw"
    normalized_dir = scenario_dir / "normalized"
    raw_dir.mkdir(parents=True, exist_ok=True)
    normalized_dir.mkdir(
        parents=True,
        exist_ok=True,
    )

    placements = []
    scripts = []
    cursor_ms = 0
    previous_duration = 0

    for position, speaker_id in enumerate(
        selected,
        start=1,
    ):
        utterance = utterances[
            (position - 1) % len(utterances)
        ]
        raw = raw_dir / f"speaker-{position}.wav"
        normalized = (
            normalized_dir
            / f"speaker-{position}.wav"
        )
        synthesize(
            utterance["text"],
            speaker_id,
            raw,
        )
        normalize_to_wav(raw, normalized)
        duration = _duration_ms(normalized)

        if position > 1:
            overlap_ms = round(
                min(
                    previous_duration,
                    duration,
                )
                * overlap_ratio
            )
            cursor_ms = max(
                0,
                cursor_ms - overlap_ms,
            )

        label = f"speaker-{position}"
        placements.append(
            (label, normalized, cursor_ms)
        )
        scripts.append({
            "speaker_label": label,
            "voicevox_speaker_id": speaker_id,
            "utterance_id": utterance["id"],
            "text": utterance["text"],
            "start_ms": cursor_ms,
        })
        cursor_ms += duration
        previous_duration = duration

    mix(
        placements,
        scenario_dir / "audio.wav",
        scenario_dir / "speaker-reference.json",
    )
    metadata = {
        "schema_version": 1,
        "id": scenario_id,
        "speaker_count": speaker_count,
        "collapse_policy":
            "first7-plus-other"
            if speaker_count > 7
            else "tracked-only",
        "overlap_ratio": overlap_ratio,
        "scripts": scripts,
    }
    (scenario_dir / "scenario.json").write_text(
        json.dumps(
            metadata,
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
        ) + "\n",
        encoding="utf-8",
    )
    return metadata
