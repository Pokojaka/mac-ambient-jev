import json
import wave

import pytest

from common.voicevox_cli import VoiceStyle
from voicevox_suite import generate_scenario


MANIFEST = {
    "utterances": [
        {"id": "u1", "text": "一つ目です。"},
        {"id": "u2", "text": "二つ目です。"},
    ],
    "diarization_scenarios": [
        {
            "id": "speakers-3",
            "speaker_count": 3,
            "placement_overlap_factor": 0.25,
        },
    ],
}


def voice(index: int, uuid: str | None = None) -> VoiceStyle:
    return VoiceStyle(
        speaker_uuid=uuid or f"uuid-{index}",
        speaker_name=f"character-{index}",
        style_id=index,
        style_name="normal",
    )


def fake_synthesize(text, style_id, output):
    # 100 ms silence, 800 ms speech, 100 ms silence at 16 kHz.
    frames = (
        b"\x00\x00" * 1_600
        + (4_000).to_bytes(2, "little", signed=True) * 12_800
        + b"\x00\x00" * 1_600
    )
    with wave.open(str(output), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(16_000)
        wav.writeframes(frames)
    return {"text": text, "style_id": style_id}


def test_scenario_records_engine_voices_queries_hashes_and_overlap(tmp_path):
    metadata = generate_scenario(
        MANIFEST,
        scenario_id="speakers-3",
        voices=[voice(1), voice(2), voice(3)],
        engine_version="0.25.0",
        output_root=tmp_path,
        synthesize=fake_synthesize,
    )

    assert metadata["engine"] == {"name": "voicevox", "version": "0.25.0"}
    assert metadata["placement_overlap_factor"] == 0.25
    # Each 1000 ms clip starts 250 ms before the previous one ends, but
    # 100 ms of each side is TTS silence, so speech overlaps for only 50 ms
    # at each of the two joins within 2300 ms of speech.
    assert metadata["measured_overlap_ratio"] == pytest.approx(100 / 2_300)
    assert [script["voice"]["speaker_uuid"] for script in metadata["scripts"]] == [
        "uuid-1",
        "uuid-2",
        "uuid-3",
    ]
    assert metadata["scripts"][1]["audio_query"] == {
        "text": "二つ目です。",
        "style_id": 2,
    }
    assert all(len(script["raw_wav_sha256"]) == 64 for script in metadata["scripts"])
    assert len(metadata["audio_sha256"]) == 64

    reference = json.loads(
        (tmp_path / "speakers-3" / "speaker-reference.json").read_text()
    )
    assert reference[0] == {
        "speaker_label": "speaker-1",
        "start_ms": 100,
        "end_ms": 900,
    }
    assert json.loads(
        (tmp_path / "speakers-3" / "scenario.json").read_text()
    ) == metadata


def test_scenario_requires_enough_distinct_characters(tmp_path):
    with pytest.raises(ValueError, match="needs 3 distinct"):
        generate_scenario(
            MANIFEST,
            scenario_id="speakers-3",
            voices=[voice(1), voice(2)],
            engine_version="0.25.0",
            output_root=tmp_path,
            synthesize=fake_synthesize,
        )


def test_scenario_rejects_two_styles_of_one_character(tmp_path):
    with pytest.raises(ValueError, match="distinct VOICEVOX characters"):
        generate_scenario(
            MANIFEST,
            scenario_id="speakers-3",
            voices=[voice(1), voice(2, uuid="uuid-1"), voice(3)],
            engine_version="0.25.0",
            output_root=tmp_path,
            synthesize=fake_synthesize,
        )
