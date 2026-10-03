import json
from pathlib import Path


def test_voicevox_manifest_declares_every_required_scenario():
    root = Path(__file__).resolve().parents[3]
    manifest = json.loads(
        (root / "tools/corpora/voicevox-ja-core-v1.json").read_text(
            encoding="utf-8"
        )
    )
    scenarios = manifest["diarization_scenarios"]

    assert {item["speaker_count"] for item in scenarios} >= {2, 4, 7, 8, 10}
    for item in scenarios:
        assert 0 <= item["placement_overlap_factor"] < 1
