#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import io
import math
import struct
import tempfile
import unittest
import wave
from pathlib import Path
from unittest import mock

import generate_qwen3_asr_token_reference as reference


class SparseLogits:
    def __init__(self, token_count: int, preferred_token: int, preferred_value: float) -> None:
        self.token_count = token_count
        self.preferred_token = preferred_token
        self.preferred_value = preferred_value

    def __len__(self) -> int:
        return self.token_count

    def __iter__(self):
        for token_id in range(self.token_count):
            if token_id == self.preferred_token:
                yield self.preferred_value
            else:
                yield 0.0


def make_wav(
    samples: tuple[int, ...], channels: int, sample_rate: int
) -> bytes:
    output = io.BytesIO()
    with wave.open(output, "wb") as wav_file:
        wav_file.setnchannels(channels)
        wav_file.setsampwidth(2)
        wav_file.setframerate(sample_rate)
        if channels == 1:
            wav_file.writeframes(struct.pack(f"<{len(samples)}h", *samples))
        else:
            interleaved = tuple(sample for value in samples for sample in (value, value))
            wav_file.writeframes(struct.pack(f"<{len(interleaved)}h", *interleaved))
    return output.getvalue()


class TokenReferenceTests(unittest.TestCase):
    def test_prompt_ids_and_audio_offset_are_exact(self) -> None:
        self.assertEqual(
            reference.build_prompt_ids(2),
            [
                151644,
                8948,
                198,
                151645,
                198,
                151644,
                872,
                198,
                151669,
                151676,
                151676,
                151670,
                151645,
                198,
                151644,
                77091,
                198,
                11528,
                11937,
                151704,
            ],
        )
        self.assertEqual(reference.AUDIO_OFFSET, 9)

    def test_greedy_ties_choose_lowest_token_id(self) -> None:
        self.assertEqual(reference.select_greedy_token([3.0, 4.0, 4.0, 1.0], [], False), 1)

    def test_all_negative_infinity_tie_chooses_lowest_token_id(self) -> None:
        self.assertEqual(
            reference.select_greedy_token([-math.inf, -math.inf, -math.inf], [], False), 0
        )

    def test_masking_every_token_chooses_lowest_id_after_all_scores_become_negative_infinity(
        self,
    ) -> None:
        generated_ids = [2, 1, 0, 2, 1, 1, 2, 1, 2, 2, 1]
        self.assertEqual(
            reference.select_greedy_token([10.0, 20.0, 30.0], generated_ids, True), 0
        )

    def test_transcript_token_ids_without_marker_remove_stop_ids(self) -> None:
        self.assertEqual(
            reference.transcript_token_ids([10, reference.STOP_TOKEN_IDS[0], 11]), [10, 11]
        )

    def test_transcript_token_ids_after_single_marker_exclude_marker(self) -> None:
        self.assertEqual(
            reference.transcript_token_ids([7, reference.AUDIO_TEXT_MARKER_ID, 8, 9]), [8, 9]
        )

    def test_transcript_token_ids_after_last_of_multiple_markers_exclude_markers(self) -> None:
        self.assertEqual(
            reference.transcript_token_ids(
                [7, reference.AUDIO_TEXT_MARKER_ID, 8, reference.AUDIO_TEXT_MARKER_ID, 9]
            ),
            [9],
        )

    def test_transcript_token_ids_remove_all_stop_ids(self) -> None:
        self.assertEqual(
            reference.transcript_token_ids(
                [1, reference.STOP_TOKEN_IDS[0], 2, reference.STOP_TOKEN_IDS[1], 3]
            ),
            [1, 2, 3],
        )

    def test_both_stop_tokens_are_inclusive_and_do_not_trigger_an_extra_step(self) -> None:
        for stop_token_id in reference.STOP_TOKEN_IDS:
            with self.subTest(stop_token_id=stop_token_id):
                calls: list[tuple[int, int]] = []
                final_logits = SparseLogits(stop_token_id + 1, stop_token_id, 1.0)

                def next_logits(last_token_id: int, generated_count: int):
                    calls.append((last_token_id, generated_count))
                    return final_logits

                generated, ended_at_cap = reference.greedy_generate(
                    [0.0, 1.0], next_logits, 52_907
                )
                self.assertEqual(generated, [1, stop_token_id])
                self.assertFalse(ended_at_cap)
                self.assertEqual(calls, [(1, 1)])

    def test_token_cap_is_inclusive_and_has_no_unnecessary_step(self) -> None:
        calls: list[tuple[int, int]] = []

        def next_logits(last_token_id: int, generated_count: int) -> list[float]:
            calls.append((last_token_id, generated_count))
            return [0.0, 1.0]

        generated, ended_at_cap = reference.greedy_generate([0.0, 1.0], next_logits, 52_907)
        self.assertEqual(generated, [1] * 448)
        self.assertTrue(ended_at_cap)
        self.assertEqual(len(calls), 447)
        self.assertEqual(calls[-1], (1, 447))

    def test_no_repeat_trigram_masks_only_a_repeated_generated_completion(self) -> None:
        logits = [0.0, 0.0, 0.0, 10.0, 5.0]
        generated_completion = [1, 2, 3, 1, 2]
        self.assertEqual(
            reference.select_greedy_token(logits, generated_completion, True), 4
        )

    def test_no_repeat_trigram_is_disabled_at_fifteen_seconds(self) -> None:
        self.assertIsNone(reference.no_repeat_ngram_size(15 * 16_000))
        generated, ended_at_cap = reference.greedy_generate(
            [0.0, 2.0], lambda _last, _count: [0.0, 2.0], 15 * 16_000
        )
        self.assertTrue(ended_at_cap)
        self.assertEqual(generated, [1] * 448)

    def test_no_repeat_trigram_is_enabled_only_after_fifteen_seconds(self) -> None:
        self.assertEqual(reference.no_repeat_ngram_size(15 * 16_000 + 1), 3)
        def next_logits(_last: int, generated_count: int):
            if generated_count == 4:
                return SparseLogits(
                    reference.STOP_TOKEN_IDS[0] + 1,
                    reference.STOP_TOKEN_IDS[0],
                    1.0,
                )
            return [0.0, 0.0, 0.0, 2.0]

        generated, ended_at_cap = reference.greedy_generate(
            [0.0, 0.0, 0.0, 2.0], next_logits, 15 * 16_000 + 1
        )
        self.assertFalse(ended_at_cap)
        self.assertEqual(generated, [3, 3, 3, 0, reference.STOP_TOKEN_IDS[0]])

    def test_empty_and_nan_logits_are_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "empty"):
            reference.select_greedy_token([], [], False)
        with self.assertRaisesRegex(ValueError, "NaN"):
            reference.select_greedy_token([0.0, float("nan")], [], False)

    def test_pcm16_wav_normalizes_to_float32_range(self) -> None:
        pcm_values = (-32_768, -1, 0, 1, 32_767)
        wav_data = make_wav(pcm_values, channels=1, sample_rate=reference.SAMPLE_RATE)
        pcm_bytes = reference.parse_pcm16_wav(wav_data, len(pcm_values), "sample")
        normalized = reference.normalize_pcm16_samples(pcm_bytes)
        self.assertEqual(normalized.typecode, "f")
        self.assertEqual(normalized.itemsize, 4)
        self.assertEqual(
            list(normalized),
            [-1.0, -1.0 / 32_768, 0.0, 1.0 / 32_768, 32_767.0 / 32_768],
        )

    def test_fixed_voicevox_wavs_match_hashes_and_sample_counts(self) -> None:
        for clip_id, filename, sample_count, expected_sha256 in reference.EXPECTED_CLIPS:
            with self.subTest(clip_id=clip_id):
                wav_data = (reference.AUDIO_DIRECTORY / filename).read_bytes()
                self.assertEqual(hashlib.sha256(wav_data).hexdigest(), expected_sha256)
                pcm_bytes = reference.parse_pcm16_wav(wav_data, sample_count, clip_id)
                self.assertEqual(len(reference.normalize_pcm16_samples(pcm_bytes)), sample_count)

    def test_invalid_wav_format_and_incomplete_pcm_are_rejected(self) -> None:
        stereo_wav = make_wav((1, 2), channels=2, sample_rate=reference.SAMPLE_RATE)
        with self.assertRaisesRegex(reference.ReferenceError, "mono PCM16"):
            reference.parse_pcm16_wav(stereo_wav, 2, "stereo")

        wrong_rate = make_wav((1, 2), channels=1, sample_rate=8_000)
        with self.assertRaisesRegex(reference.ReferenceError, "mono PCM16"):
            reference.parse_pcm16_wav(wrong_rate, 2, "rate")

        with self.assertRaisesRegex(reference.ReferenceError, "incomplete"):
            reference.normalize_pcm16_samples(b"\x00")

    def test_package_version_mismatch_fails_before_importing_runtime_packages(self) -> None:
        installed = dict(reference.REQUIRED_PACKAGES)
        installed["numpy"] = "2.2.5"
        with mock.patch.object(reference.sys, "version_info", (3, 12, 0)), mock.patch.object(
            reference, "installed_versions", return_value=installed
        ):
            with self.assertRaisesRegex(reference.ReferenceError, "numpy==2.2.6"):
                reference.validate_environment()

    def test_all_six_model_file_hashes_are_checked_and_recorded(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            model_directory = Path(directory)
            manifest_files = []
            for index in range(6):
                name = f"model-{index}.bin"
                payload = f"file {index}".encode()
                (model_directory / name).write_bytes(payload)
                manifest_files.append(
                    {
                        "name": name,
                        "byteCount": len(payload),
                        "sha256": hashlib.sha256(payload).hexdigest(),
                    }
                )
            model = {"files": manifest_files}
            verified = reference.validate_model_files(model_directory, model)
            self.assertEqual(len(verified), 6)
            self.assertEqual(
                verified[0],
                {
                    "name": "model-0.bin",
                    "byte_count": len(b"file 0"),
                    "sha256": hashlib.sha256(b"file 0").hexdigest(),
                },
            )

            (model_directory / "model-5.bin").write_bytes(b"wrong!")
            with self.assertRaisesRegex(reference.ReferenceError, "SHA-256 mismatch"):
                reference.validate_model_files(model_directory, model)


if __name__ == "__main__":
    unittest.main()
