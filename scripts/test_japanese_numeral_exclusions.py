#!/usr/bin/env python3
"""漢数字表示の除外句リストの生成規則と、コミット済みの生成物が最新であることを検証する。"""
import pathlib
import tempfile
import unittest

from generate_japanese_numeral_exclusions import (
    exclusion_phrases,
    read_labels,
    swift_source,
    would_convert,
)

ROOT = pathlib.Path(__file__).resolve().parent.parent
LABELS = ROOT / "tools/numeral-exclusions/labels.tsv"
SWIFT = ROOT / "app/MacAmbientJev/Sources/MacAmbientJevCore/JapaneseNumeralExclusionPhrases.swift"


class ExclusionPhraseTests(unittest.TestCase):
    def test_committed_swift_matches_labels(self):
        self.assertEqual(SWIFT.read_text(encoding="utf-8"),
                         swift_source(exclusion_phrases(read_labels(LABELS))))

    def test_disambiguation_suffix_is_dropped(self):
        self.assertEqual(exclusion_phrases([("EXCLUDE", "一ノ宮駅 (群馬県)")]), ["一ノ宮駅"])

    def test_bare_number_and_numeral_free_bases_are_dropped(self):
        rows = [("EXCLUDE", "一 (緑茶飲料)"), ("EXCLUDE", "OUT (二ノ宮知子の漫画)")]
        self.assertEqual(exclusion_phrases(rows), [])

    def test_numeral_word_without_suffix_is_kept(self):
        self.assertEqual(exclusion_phrases([("EXCLUDE", "九九")]), ["九九"])

    def test_keep_rows_are_not_phrases(self):
        self.assertEqual(exclusion_phrases([("KEEP", "七百"), ("EXCLUDE", "万が一")]), ["万が一"])

    def test_malformed_label_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "labels.tsv"
            path.write_text("UNKNOWN\t一ノ瀬\n", encoding="utf-8")
            with self.assertRaises(ValueError):
                read_labels(path)

    def test_candidate_rule_skips_kanji_digit_and_fraction_neighbours(self):
        self.assertTrue(would_convert("万が一"))
        self.assertFalse(would_convert("二十人"))
        self.assertFalse(would_convert("3二"))
        self.assertFalse(would_convert("三分の一"))

    def test_swift_literal_escapes_quotes(self):
        self.assertIn('"\\"一\\""', swift_source(['"一"']))


if __name__ == "__main__":
    unittest.main()
