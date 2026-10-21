from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("compare_diarization_runs.py")
SPEC = importlib.util.spec_from_file_location("compare_diarization_runs", SCRIPT)
compare_runs = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(compare_runs)

AUDIO = {"sha256": "ab" * 32, "sample_count": 32000, "sample_rate": 16000}


def run(spans: list[tuple[str, int, int]], audio: dict = AUDIO, count: int | None = None) -> dict:
    return {
        "schema_version": 1,
        "audio": audio,
        "provenance": {"engine": "fake"},
        "raw_spans": [
            {"speaker_id": speaker, "start_frame": start, "end_frame": end, "confidence": None}
            for speaker, start, end in spans
        ],
        "raw_speaker_count": len({speaker for speaker, _, _ in spans}) if count is None else count,
    }


class CompareTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.calls: list[tuple[list[dict], list[dict]]] = []

    def path(self, name: str, content: dict) -> Path:
        path = Path(self.directory.name) / name
        path.write_text(json.dumps(content), encoding="utf-8")
        return path

    def evaluate(self, reference: list[dict], hypothesis: list[dict]) -> dict:
        self.calls.append((reference, hypothesis))
        return {"der": 0.25}

    def test_frame_to_ms_rounds_half_to_even(self) -> None:
        cases = {0: 0, 7: 0, 8: 0, 9: 1, 16: 1, 24: 2, 40: 2, 56: 4, 8000: 500}
        for frame, expected in cases.items():
            self.assertEqual(compare_runs.frame_to_ms(frame), expected, frame)

    def test_compare_converts_raw_spans_and_counts_speakers(self) -> None:
        reference = self.path("ref.json", run([("a", 0, 16000), ("b", 16000, 32000)]))
        hypothesis = self.path("hyp.json", run([("x", 0, 32000)]))
        result = compare_runs.compare(reference, hypothesis, self.evaluate)
        self.assertEqual(result["reference_speaker_count"], 2)
        self.assertEqual(result["hypothesis_speaker_count"], 1)
        self.assertEqual(result["standard"], {"der": 0.25})
        self.assertEqual(self.calls[0][0][1], {"start_ms": 1000, "end_ms": 2000, "speaker_label": "b"})
        self.assertEqual(self.calls[0][1], [{"start_ms": 0, "end_ms": 2000, "speaker_label": "x"}])

    def test_rejects_audio_mismatch(self) -> None:
        reference = self.path("ref.json", run([("a", 0, 16000)]))
        other = self.path("hyp.json", run([("a", 0, 16000)], audio={**AUDIO, "sha256": "cd" * 32}))
        with self.assertRaisesRegex(compare_runs.ComparisonError, "audio mismatch"):
            compare_runs.compare(reference, other, self.evaluate)

    def test_rejects_inconsistent_speaker_count_and_bad_schema(self) -> None:
        good = self.path("good.json", run([("a", 0, 16000)]))
        miscounted = self.path("count.json", run([("a", 0, 16000)], count=2))
        with self.assertRaisesRegex(compare_runs.ComparisonError, "raw_speaker_count"):
            compare_runs.compare(good, miscounted, self.evaluate)
        wrong = self.path("schema.json", {**run([("a", 0, 16000)]), "schema_version": 9})
        with self.assertRaisesRegex(compare_runs.ComparisonError, "schema_version"):
            compare_runs.compare(good, wrong, self.evaluate)

    def test_rejects_span_that_vanishes_in_milliseconds(self) -> None:
        good = self.path("good.json", run([("a", 0, 16000)]))
        tiny = self.path("tiny.json", run([("a", 100, 104)]))
        with self.assertRaisesRegex(compare_runs.ComparisonError, "empty or negative"):
            compare_runs.compare(good, tiny, self.evaluate)

    def test_self_disagreement_scores_every_pair(self) -> None:
        paths = [self.path(f"{index}.json", run([("a", 0, 16000)])) for index in range(3)]
        result = compare_runs.self_disagreement(paths, self.evaluate)
        self.assertEqual(result["run_count"], 3)
        self.assertEqual(len(result["pairs"]), 3)
        self.assertEqual(result["max_der"], 0.25)

    def test_arguments_require_exactly_one_mode(self) -> None:
        output = ["--min-clean-speech-ms", "500", "--output", "o.json"]
        with self.assertRaises(SystemExit):
            compare_runs.parse_arguments(output)
        with self.assertRaises(SystemExit):
            compare_runs.parse_arguments(["--reference-run", "a", *output])
        with self.assertRaises(SystemExit):
            compare_runs.parse_arguments(["--runs", "a", *output])
        with self.assertRaises(SystemExit):
            compare_runs.parse_arguments(["--runs", "a", "b", "--reference-run", "a", "--hypothesis-run", "b", *output])
        args = compare_runs.parse_arguments(["--reference-run", "a", "--hypothesis-run", "b", *output])
        self.assertEqual(args.min_clean_speech_ms, 500)

    def test_output_is_never_replaced(self) -> None:
        target = Path(self.directory.name) / "out.json"
        compare_runs.write_new(target, {"a": 1})
        with self.assertRaises(FileExistsError):
            compare_runs.write_new(target, {"a": 2})


if __name__ == "__main__":
    unittest.main()
