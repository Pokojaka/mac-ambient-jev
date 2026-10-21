import pytest

from common.voicevox_cli import VoiceStyle
from generate_voicevox_diarization_scenarios import generate_scenarios
from test_voicevox_suite import MANIFEST, fake_synthesize


def voices(count):
    return [
        VoiceStyle(f"uuid-{i}", f"character-{i}", i, "normal")
        for i in range(1, count + 1)
    ]


def test_each_requested_scenario_gets_its_own_directory(tmp_path):
    manifest = {
        **MANIFEST,
        "diarization_scenarios": MANIFEST["diarization_scenarios"]
        + [
            {
                "id": "speakers-2",
                "speaker_count": 2,
                "placement_overlap_factor": 0.0,
            }
        ],
    }

    results = generate_scenarios(
        manifest,
        scenario_ids=["speakers-2", "speakers-3"],
        voices=voices(3),
        version="0.25.0",
        output_root=tmp_path,
        synthesize_fn=fake_synthesize,
    )

    assert [item["id"] for item in results] == ["speakers-2", "speakers-3"]
    assert (tmp_path / "speakers-2" / "audio.wav").is_file()
    assert (tmp_path / "speakers-3" / "audio.wav").is_file()


def test_no_scenarios_is_an_error(tmp_path):
    with pytest.raises(ValueError, match="at least one scenario"):
        generate_scenarios(
            MANIFEST,
            scenario_ids=[],
            voices=voices(3),
            version="0.25.0",
            output_root=tmp_path,
            synthesize_fn=fake_synthesize,
        )
