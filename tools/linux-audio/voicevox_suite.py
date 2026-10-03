from __future__ import annotations

import pathlib
from collections.abc import Callable
from typing import Any

from common.audio import normalize_to_wav, wav_duration_seconds
from common.files import sha256_file, write_json_atomic
from common.pcm_mix import mix, overlap_ratio
from common.voicevox_cli import VoiceStyle


SynthesizeFn = Callable[
    [str, int, pathlib.Path],
    dict[str, Any],
]


def generate_scenario(
    manifest: dict,
    *,
    scenario_id: str,
    voices: list[VoiceStyle],
    engine_version: str,
    output_root: pathlib.Path,
    synthesize: SynthesizeFn,
) -> dict:
    """Generates a multi-speaker scenario with one distinct person per slot.

    Each clip starts placement_overlap_factor times the shorter adjacent clip
    before the previous clip ends; measured_overlap_ratio is the overlap
    share of the resulting speech-activity timeline.
    """
    matches = [
        item
        for item in manifest["diarization_scenarios"]
        if item["id"] == scenario_id
    ]
    if len(matches) != 1:
        raise ValueError(f"unknown scenario: {scenario_id}")
    scenario = matches[0]

    speaker_count = scenario["speaker_count"]
    people = [voice.speaker_uuid for voice in voices]
    if len(set(people)) != len(people):
        raise ValueError("voices must be distinct VOICEVOX characters")
    if len(voices) < speaker_count:
        raise ValueError(
            f"{scenario_id} needs {speaker_count} distinct VOICEVOX "
            f"characters, only {len(voices)} are available"
        )
    selected = voices[:speaker_count]

    utterances = manifest["utterances"]
    if not utterances:
        raise ValueError("utterances are required")

    placement_overlap_factor = scenario["placement_overlap_factor"]
    if not 0 <= placement_overlap_factor < 1:
        raise ValueError(
            "placement_overlap_factor must be in [0, 1)"
        )

    scenario_dir = output_root / scenario_id
    raw_dir = scenario_dir / "raw"
    normalized_dir = scenario_dir / "normalized"
    raw_dir.mkdir(parents=True, exist_ok=True)
    normalized_dir.mkdir(parents=True, exist_ok=True)

    placements = []
    scripts = []
    cursor_ms = 0
    previous_duration = 0

    for position, voice in enumerate(selected, start=1):
        utterance = utterances[(position - 1) % len(utterances)]
        raw = raw_dir / f"speaker-{position}.wav"
        normalized = normalized_dir / f"speaker-{position}.wav"
        audio_query = synthesize(
            utterance["text"],
            voice.style_id,
            raw,
        )
        normalize_to_wav(raw, normalized)
        duration = round(wav_duration_seconds(normalized) * 1000)

        if position > 1:
            overlap_ms = round(
                min(previous_duration, duration)
                * placement_overlap_factor
            )
            cursor_ms = max(0, cursor_ms - overlap_ms)

        label = f"speaker-{position}"
        placements.append((label, normalized, cursor_ms))
        scripts.append({
            "speaker_label": label,
            "voice": voice.metadata(),
            "utterance_id": utterance["id"],
            "text": utterance["text"],
            "audio_query": audio_query,
            "raw_wav_sha256": sha256_file(raw),
            "start_ms": cursor_ms,
        })
        cursor_ms += duration
        previous_duration = duration

    audio_path = scenario_dir / "audio.wav"
    reference_spans = mix(
        placements,
        audio_path,
        scenario_dir / "speaker-reference.json",
    )
    metadata = {
        "schema_version": 1,
        "id": scenario_id,
        "engine": {
            "name": "voicevox",
            "version": engine_version,
        },
        "speaker_count": speaker_count,
        "collapse_policy":
            "first7-plus-other"
            if speaker_count > 7
            else "tracked-only",
        "placement_overlap_factor": placement_overlap_factor,
        "measured_overlap_ratio": overlap_ratio(reference_spans),
        "audio_sha256": sha256_file(audio_path),
        "scripts": scripts,
    }
    write_json_atomic(scenario_dir / "scenario.json", metadata)
    return metadata
