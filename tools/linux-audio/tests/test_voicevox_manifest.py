import json
from pathlib import Path


def test_voicevox_manifest_covers_required_diarization_speaker_counts():
    root = Path(__file__).resolve().parents[3]
    manifest = json.loads(
        (
            root / "tools/corpora/voicevox-ja-core-v1.json"
        ).read_text(encoding="utf-8")
    )
    counts = {
        int(item["speaker_count"])
        for item in manifest["diarization_scenarios"]
    }
    assert {2, 4, 7, 8, 10} <= counts
