#!/usr/bin/env python3
from __future__ import annotations

import io
import json
import struct
import tempfile
import unittest
import wave
from pathlib import Path
from unittest.mock import patch

import generate_qwen3_asr_fixtures as fixtures


VALID_QUERY = dict(fixtures.EXPECTED_QUERY_PARAMETERS)
VALID_STYLE = fixtures.voicevox_cli.VoiceStyle(
    speaker_uuid=fixtures.SPEAKER_UUID,
    speaker_name=fixtures.SPEAKER_NAME,
    style_id=fixtures.STYLE_ID,
    style_name=fixtures.STYLE_NAME,
)


class Qwen3ASRFixtureTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.destination = Path(self.temporary.name) / "Resources"
        self.destination.mkdir()
        self.short_frames = 96_000
        self.long_frames = 480_000
        self.source_format = (1, 2, fixtures.SOURCE_RATE)
        self.audio_query = dict(VALID_QUERY)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def mock_engine(self, *, style, version):
        return (
            patch.object(fixtures.voicevox_cli, "engine_version", return_value=version),
            patch.object(fixtures.voicevox_cli, "voice_styles", return_value=[style]),
            patch.object(fixtures.voicevox_cli, "synthesize", side_effect=self.write_source),
        )

    def write_source(
        self,
        *,
        base_url: str,
        text: str,
        style_id: int,
        output: Path,
    ) -> dict[str, bool | int | float]:
        self.assertEqual(base_url, "http://127.0.0.1:50021")
        self.assertEqual(style_id, fixtures.STYLE_ID)
        frames = self.frames_for_text(text)
        channels, sample_width, sample_rate = self.source_format
        with wave.open(str(output), "wb") as source:
            source.setnchannels(channels)
            source.setsampwidth(sample_width)
            source.setframerate(sample_rate)
            source.writeframes(b"\0" * (frames * channels * sample_width))
        return dict(self.audio_query)

    def frames_for_text(self, text: str) -> int:
        corpus_texts = fixtures.load_fixture_texts(fixtures.CORPUS_PATH)
        if text == corpus_texts["short"]:
            return self.short_frames
        if text == corpus_texts["long"]:
            return self.long_frames
        raise AssertionError(f"unexpected synthesis text: {text!r}")

    def assert_no_output_files(self) -> None:
        self.assertEqual(list(self.destination.iterdir()), [])

    def test_engine_version_mismatch_fails_before_synthesis(self) -> None:
        engine_version, styles, synthesize = self.mock_engine(style=VALID_STYLE, version="0.25.1")
        with engine_version, styles, synthesize as synthesize_mock:
            with self.assertRaisesRegex(fixtures.FixtureError, "0.25.2"):
                fixtures.generate(
                    base_url="http://127.0.0.1:50021", destination=self.destination
                )
        synthesize_mock.assert_not_called()
        self.assert_no_output_files()

    def test_speaker_mismatch_fails_before_synthesis(self) -> None:
        wrong_style = fixtures.voicevox_cli.VoiceStyle(
            speaker_uuid=fixtures.SPEAKER_UUID,
            speaker_name=fixtures.SPEAKER_NAME,
            style_id=1,
            style_name=fixtures.STYLE_NAME,
        )
        engine_version, styles, synthesize = self.mock_engine(style=wrong_style, version=fixtures.ENGINE_VERSION)
        with engine_version, styles, synthesize as synthesize_mock:
            with self.assertRaisesRegex(fixtures.FixtureError, "speaker/style"):
                fixtures.generate(
                    base_url="http://127.0.0.1:50021", destination=self.destination
                )
        synthesize_mock.assert_not_called()
        self.assert_no_output_files()

    def test_invalid_audio_query_fails_without_publishing(self) -> None:
        self.audio_query["speedScale"] = 1.1
        engine_version, styles, synthesize = self.mock_engine(style=VALID_STYLE, version=fixtures.ENGINE_VERSION)
        with engine_version, styles, synthesize:
            with self.assertRaisesRegex(fixtures.FixtureError, "speedScale"):
                fixtures.generate(
                    base_url="http://127.0.0.1:50021", destination=self.destination
                )
        self.assert_no_output_files()

    def test_invalid_source_format_fails_without_publishing(self) -> None:
        self.source_format = (2, 2, fixtures.SOURCE_RATE)
        engine_version, styles, synthesize = self.mock_engine(style=VALID_STYLE, version=fixtures.ENGINE_VERSION)
        with engine_version, styles, synthesize:
            with self.assertRaisesRegex(fixtures.FixtureError, "24000 Hz"):
                fixtures.generate(
                    base_url="http://127.0.0.1:50021", destination=self.destination
                )
        self.assert_no_output_files()

    def test_incomplete_pcm16_source_fails(self) -> None:
        source_path = Path(self.temporary.name) / "incomplete.wav"
        source_buffer = io.BytesIO()
        with wave.open(source_buffer, "wb") as source:
            source.setnchannels(1)
            source.setsampwidth(2)
            source.setframerate(fixtures.SOURCE_RATE)
            source.writeframes(b"\0\0")
        wav_data = bytearray(source_buffer.getvalue())
        struct.pack_into("<I", wav_data, 4, len(wav_data) + 2 - 8)
        struct.pack_into("<I", wav_data, 40, 3)
        wav_data.extend(b"\0\0")
        source_path.write_bytes(wav_data)
        with self.assertRaisesRegex(fixtures.FixtureError, "不完全な PCM16 sample"):
            fixtures.read_source_samples(source_path)

    def test_invalid_duration_fails_without_publishing(self) -> None:
        self.long_frames = 15 * fixtures.SOURCE_RATE
        engine_version, styles, synthesize = self.mock_engine(style=VALID_STYLE, version=fixtures.ENGINE_VERSION)
        with engine_version, styles, synthesize:
            with self.assertRaisesRegex(fixtures.FixtureError, "long fixture の長さ"):
                fixtures.generate(
                    base_url="http://127.0.0.1:50021", destination=self.destination
                )
        self.assert_no_output_files()

    def test_resampling_uses_integer_ties_to_even_and_endpoint_clamp(self) -> None:
        self.assertEqual(fixtures.round_ratio_ties_to_even(1, 2), 0)
        self.assertEqual(fixtures.round_ratio_ties_to_even(3, 2), 2)
        self.assertEqual(fixtures.round_ratio_ties_to_even(5, 2), 2)
        self.assertEqual(fixtures.round_ratio_ties_to_even(-3, 2), -2)
        self.assertEqual(fixtures.resample_linear([0, 1, 2, 3, 4]), [0, 2, 3, 4])
        self.assertEqual(fixtures.resample_linear([-2, -1]), [-2, -1])

    def test_pcm_output_has_canonical_unpadded_wav_header(self) -> None:
        samples = [-32_768, -1, 0, 1, 32_767]
        actual = fixtures.make_pcm16_wav(samples)
        sample_bytes = struct.pack("<5h", *samples)
        expected_header = struct.pack(
            "<4sI4s4sIHHIIHH4sI",
            b"RIFF",
            36 + len(sample_bytes),
            b"WAVE",
            b"fmt ",
            16,
            1,
            1,
            fixtures.TARGET_RATE,
            fixtures.TARGET_RATE * 2,
            2,
            16,
            b"data",
            len(sample_bytes),
        )
        self.assertEqual(actual, expected_header + sample_bytes)
        with wave.open(io.BytesIO(actual), "rb") as wav_file:
            self.assertEqual(wav_file.getnchannels(), 1)
            self.assertEqual(wav_file.getsampwidth(), 2)
            self.assertEqual(wav_file.getframerate(), 16_000)
            self.assertEqual(wav_file.getnframes(), len(samples))
            self.assertEqual(wav_file.readframes(len(samples)), sample_bytes)

    def test_corpus_missing_and_duplicate_ids_fail(self) -> None:
        corpus_path = Path(self.temporary.name) / "corpus.json"
        complete = [
            {"id": "general-001", "text": "short"},
            {"id": "long-001", "text": "first"},
            {"id": "statistics-001", "text": "second"},
            {"id": "question-001", "text": "third"},
        ]
        corpus_path.write_text(
            json.dumps({"utterances": complete}), encoding="utf-8"
        )
        self.assertEqual(
            fixtures.load_fixture_texts(corpus_path),
            {"short": "short", "long": "firstsecondthird"},
        )

        corpus_path.write_text(
            json.dumps({"utterances": complete[1:]}), encoding="utf-8"
        )
        with self.assertRaisesRegex(fixtures.FixtureError, "general-001"):
            fixtures.load_fixture_texts(corpus_path)

        duplicate = complete + [{"id": "long-001", "text": "duplicate"}]
        corpus_path.write_text(
            json.dumps({"utterances": duplicate}), encoding="utf-8"
        )
        with self.assertRaisesRegex(fixtures.FixtureError, "重複.*long-001"):
            fixtures.load_fixture_texts(corpus_path)

    def test_success_generates_both_outputs_after_validation(self) -> None:
        engine_version, styles, synthesize = self.mock_engine(style=VALID_STYLE, version=fixtures.ENGINE_VERSION)
        with engine_version, styles, synthesize as synthesize_mock:
            fixtures.generate(
                base_url="http://127.0.0.1:50021", destination=self.destination
            )
        self.assertEqual(synthesize_mock.call_count, 2)
        short_path = self.destination / fixtures.OUTPUT_NAMES["short"]
        long_path = self.destination / fixtures.OUTPUT_NAMES["long"]
        self.assertTrue(short_path.is_file())
        self.assertTrue(long_path.is_file())
        with wave.open(str(short_path), "rb") as short_wav:
            self.assertEqual(short_wav.getframerate(), fixtures.TARGET_RATE)
            self.assertEqual(short_wav.getnframes(), self.short_frames * 2 // 3)
        with wave.open(str(long_path), "rb") as long_wav:
            self.assertEqual(long_wav.getframerate(), fixtures.TARGET_RATE)
            self.assertEqual(long_wav.getnframes(), self.long_frames * 2 // 3)


if __name__ == "__main__":
    unittest.main()
