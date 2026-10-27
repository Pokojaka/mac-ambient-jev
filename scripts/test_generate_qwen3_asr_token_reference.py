#!/usr/bin/env python3
from __future__ import annotations

from collections.abc import Mapping
import hashlib
import io
import json
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


class FakeTokenizer:
    def __init__(
        self,
        special_ids: Mapping[str, int | None],
        encoded_texts: Mapping[str, tuple[int, ...]],
    ) -> None:
        self.special_ids = {
            "<|im_start|>": 151644,
            "<|im_end|>": 151645,
            "<|audio_start|>": 151669,
            "<|audio_pad|>": 151676,
            "<|audio_end|>": 151670,
            "<|endoftext|>": 151643,
            "<asr_text>": 151704,
        }
        self.special_ids.update(special_ids)
        self.encoded_texts = {
            "system": (8948,),
            "user": (872,),
            "assistant": (77091,),
            "\n": (198,),
            "language ja": (11528, 11937),
            "language Japanese": (11528, 10769),
        }
        self.encoded_texts.update(encoded_texts)
        self.lookup_calls: list[str] = []
        self.encode_calls: list[tuple[str, bool]] = []

    def token_to_id(self, token: str):
        self.lookup_calls.append(token)
        return self.special_ids.get(token)

    def encode(self, text: str, add_special_tokens: bool):
        self.encode_calls.append((text, add_special_tokens))
        return type("Encoding", (), {"ids": self.encoded_texts[text]})()


def write_audio_manifest(path: Path, clips: list[dict]) -> Path:
    path.write_text(
        json.dumps({"schema_version": 1, "clips": clips}), encoding="utf-8"
    )
    return path


def manifest_clip(clip_id: str, filename: str, wav_data: bytes, sample_count: int) -> dict:
    return {
        "id": clip_id,
        "file": filename,
        "sample_count": sample_count,
        "sha256": hashlib.sha256(wav_data).hexdigest(),
    }


class FakeSamples:
    def __init__(self, values, dtype) -> None:
        self.shape = (len(values),)
        self.dtype = dtype


class FakeNumpy:
    float32 = "float32"

    @staticmethod
    def asarray(values, dtype):
        return FakeSamples(values, dtype)

    @staticmethod
    def isfinite(_samples):
        return type("FiniteValues", (), {"all": staticmethod(lambda: True)})()


class TokenReferenceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tokenizer = FakeTokenizer({}, {})
        self.prompt_tokens = reference.load_prompt_tokens(self.tokenizer, "ja")

    def test_prompt_ids_and_audio_offset_are_exact(self) -> None:
        self.assertEqual(
            reference.build_prompt_ids(2, self.prompt_tokens),
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
        self.assertEqual(self.prompt_tokens.audio_offset, 9)

    def test_prompt_tokens_use_tokenizer_lookups_and_plain_encodings(self) -> None:
        self.assertEqual(
            self.tokenizer.lookup_calls,
            [
                "<|im_start|>",
                "<|im_end|>",
                "<|audio_start|>",
                "<|audio_pad|>",
                "<|audio_end|>",
                "<|endoftext|>",
                "<asr_text>",
            ],
        )
        self.assertEqual(
            self.tokenizer.encode_calls,
            [
                ("system", False),
                ("user", False),
                ("assistant", False),
                ("\n", False),
                ("language ja", False),
            ],
        )
        custom = reference.PromptTokens((4, 5), (8,), 6, (9, 10), 11)
        self.assertEqual(custom.audio_offset, len(custom.head))
        self.assertEqual(reference.build_prompt_ids(1, custom), [4, 5, 6, 8])

    def test_japanese_language_prompt_uses_pinned_token_ids(self) -> None:
        tokenizer = FakeTokenizer({}, {})
        prompt_tokens = reference.load_prompt_tokens(tokenizer, "Japanese")
        self.assertEqual(
            prompt_tokens.tail,
            (151670, 151645, 198, 151644, 77091, 198, 11528, 10769, 151704),
        )
        self.assertIn(("language Japanese", False), tokenizer.encode_calls)

    def test_invalid_language_tag_is_rejected(self) -> None:
        with self.assertRaisesRegex(reference.ReferenceError, "unsupported language tag"):
            reference.load_prompt_tokens(self.tokenizer, "japanese")

    def test_missing_special_token_is_rejected(self) -> None:
        with self.assertRaisesRegex(reference.ReferenceError, "<\\|audio_end\\|>"):
            reference.load_prompt_tokens(FakeTokenizer({"<|audio_end|>": None}, {}), "ja")

    def test_changed_special_token_id_is_rejected_with_expected_and_actual(self) -> None:
        with self.assertRaisesRegex(reference.ReferenceError, "prompt head mismatch") as raised:
            reference.load_prompt_tokens(FakeTokenizer({"<|audio_start|>": 151668}, {}), "ja")
        self.assertIn("expected", str(raised.exception))
        self.assertIn("151668", str(raised.exception))

    def test_changed_plain_tokenization_is_rejected(self) -> None:
        with self.assertRaisesRegex(reference.ReferenceError, "prompt head mismatch") as raised:
            reference.load_prompt_tokens(FakeTokenizer({}, {"system": (42,)}), "ja")
        self.assertIn("8948", str(raised.exception))
        self.assertIn("42", str(raised.exception))

    def test_changed_language_ja_encoding_is_rejected_with_expected_and_actual(self) -> None:
        with self.assertRaisesRegex(reference.ReferenceError, "prompt tail mismatch") as raised:
            reference.load_prompt_tokens(FakeTokenizer({}, {"language ja": (11528, 42)}), "ja")
        self.assertIn("11937", str(raised.exception))
        self.assertIn("42", str(raised.exception))

    def test_changed_language_japanese_encoding_is_rejected_with_expected_and_actual(self) -> None:
        with self.assertRaisesRegex(reference.ReferenceError, "prompt tail mismatch") as raised:
            reference.load_prompt_tokens(
                FakeTokenizer({}, {"language Japanese": (11528, 42)}), "Japanese"
            )
        self.assertIn("10769", str(raised.exception))
        self.assertIn("42", str(raised.exception))

    def test_changed_endoftext_id_is_rejected(self) -> None:
        with self.assertRaisesRegex(reference.ReferenceError, "stop token IDs mismatch") as raised:
            reference.load_prompt_tokens(FakeTokenizer({"<|endoftext|>": 151642}, {}), "ja")
        self.assertIn("151643", str(raised.exception))
        self.assertIn("151642", str(raised.exception))

    def test_reference_platform_metadata_uses_platform_values(self) -> None:
        with mock.patch.object(reference.platform, "system", return_value="SyntheticOS"), mock.patch.object(
            reference.platform, "machine", return_value="SyntheticArch"
        ):
            self.assertEqual(
                reference.reference_platform(),
                {"platform": "SyntheticOS", "architecture": "SyntheticArch"},
            )

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
            reference.transcript_token_ids(
                [10, self.prompt_tokens.stop_token_ids[0], 11], self.prompt_tokens
            ),
            [10, 11],
        )

    def test_transcript_token_ids_after_single_marker_exclude_marker(self) -> None:
        self.assertEqual(
            reference.transcript_token_ids(
                [7, self.prompt_tokens.audio_text_marker_id, 8, 9], self.prompt_tokens
            ),
            [8, 9],
        )

    def test_transcript_token_ids_after_last_of_multiple_markers_exclude_markers(self) -> None:
        self.assertEqual(
            reference.transcript_token_ids(
                [7, self.prompt_tokens.audio_text_marker_id, 8, self.prompt_tokens.audio_text_marker_id, 9],
                self.prompt_tokens,
            ),
            [9],
        )

    def test_transcript_token_ids_remove_all_stop_ids(self) -> None:
        self.assertEqual(
            reference.transcript_token_ids(
                [1, self.prompt_tokens.stop_token_ids[0], 2, self.prompt_tokens.stop_token_ids[1], 3],
                self.prompt_tokens,
            ),
            [1, 2, 3],
        )

    def test_both_stop_tokens_are_inclusive_and_do_not_trigger_an_extra_step(self) -> None:
        for stop_token_id in self.prompt_tokens.stop_token_ids:
            with self.subTest(stop_token_id=stop_token_id):
                calls: list[tuple[int, int]] = []
                final_logits = SparseLogits(stop_token_id + 1, stop_token_id, 1.0)

                def next_logits(last_token_id: int, generated_count: int):
                    calls.append((last_token_id, generated_count))
                    return final_logits

                generated, ended_at_cap = reference.greedy_generate(
                    [0.0, 1.0], next_logits, 52_907, self.prompt_tokens
                )
                self.assertEqual(generated, [1, stop_token_id])
                self.assertFalse(ended_at_cap)
                self.assertEqual(calls, [(1, 1)])

    def test_token_cap_is_inclusive_and_has_no_unnecessary_step(self) -> None:
        calls: list[tuple[int, int]] = []

        def next_logits(last_token_id: int, generated_count: int) -> list[float]:
            calls.append((last_token_id, generated_count))
            return [0.0, 1.0]

        generated, ended_at_cap = reference.greedy_generate(
            [0.0, 1.0], next_logits, 52_907, self.prompt_tokens
        )
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

    def test_no_repeat_trigram_rejects_out_of_range_banned_id(self) -> None:
        with self.assertRaisesRegex(ValueError, "out-of-range token ID"):
            reference.select_greedy_token([0.0, 1.0, 2.0], [5, 6, 99, 5, 6], True)

    def test_no_repeat_trigram_is_disabled_at_fifteen_seconds(self) -> None:
        self.assertIsNone(reference.no_repeat_ngram_size(15 * 16_000))
        generated, ended_at_cap = reference.greedy_generate(
            [0.0, 2.0], lambda _last, _count: [0.0, 2.0], 15 * 16_000, self.prompt_tokens
        )
        self.assertTrue(ended_at_cap)
        self.assertEqual(generated, [1] * 448)

    def test_no_repeat_trigram_is_enabled_only_after_fifteen_seconds(self) -> None:
        self.assertEqual(reference.no_repeat_ngram_size(15 * 16_000 + 1), 3)

        def next_logits(_last: int, generated_count: int):
            if generated_count == 4:
                return SparseLogits(
                    self.prompt_tokens.stop_token_ids[0] + 1,
                    self.prompt_tokens.stop_token_ids[0],
                    1.0,
                )
            return [0.0, 0.0, 0.0, 2.0]

        generated, ended_at_cap = reference.greedy_generate(
            [0.0, 0.0, 0.0, 2.0], next_logits, 15 * 16_000 + 1, self.prompt_tokens
        )
        self.assertFalse(ended_at_cap)
        self.assertEqual(generated, [3, 3, 3, 0, self.prompt_tokens.stop_token_ids[0]])

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

    def test_bundled_voicevox_clips_load_from_explicit_manifest(self) -> None:
        fixture_directory = (
            reference.REPOSITORY_ROOT
            / "app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/Resources"
        )
        historical_clips = (
            ("short", "qwen3_asr_voicevox_short.wav", 52_907,
             "2dc561b78aed55815183f51ad66e1733909bdcefccd7f745e7cf0c64eecbb0e9"),
            ("long", "qwen3_asr_voicevox_long.wav", 295_424,
             "d50f7f2a1fe9665279689e53297772aeb52c43d9068c82ab21b21fa62cac78b2"),
        )
        with tempfile.TemporaryDirectory() as directory:
            audio_directory = Path(directory)
            manifest_clips = []
            for clip_id, filename, sample_count, expected_sha256 in historical_clips:
                wav_data = (fixture_directory / filename).read_bytes()
                self.assertEqual(hashlib.sha256(wav_data).hexdigest(), expected_sha256)
                (audio_directory / filename).write_bytes(wav_data)
                manifest_clips.append(manifest_clip(clip_id, filename, wav_data, sample_count))
            manifest_path = write_audio_manifest(
                audio_directory / "historical-clips.json", manifest_clips
            )
            resolved_directory, clips = reference.load_audio_manifest(manifest_path)
            self.assertEqual([clip[0] for clip in clips], ["short", "long"])
            for clip in clips:
                samples, digest, sample_count = reference.load_clip_samples(
                    resolved_directory, clip, FakeNumpy
                )
                self.assertEqual(samples.shape, (clip[2],))
                self.assertEqual(digest, clip[3])
                self.assertEqual(sample_count, clip[2])

    def test_audio_manifest_rejects_duplicate_ids_and_files(self) -> None:
        wav_data = make_wav((1, 2), channels=1, sample_rate=reference.SAMPLE_RATE)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "clip.wav").write_bytes(wav_data)
            valid = manifest_clip("first", "clip.wav", wav_data, 2)
            cases = (
                ([valid, {**valid, "file": "second.wav"}], "duplicate clip id"),
                ([valid, {**valid, "id": "second"}], "duplicate clip file"),
            )
            for index, (clips, message) in enumerate(cases):
                with self.subTest(message=message):
                    path = write_audio_manifest(root / f"duplicate-{index}.json", clips)
                    with self.assertRaisesRegex(reference.ReferenceError, message):
                        reference.load_audio_manifest(path)

    def test_audio_manifest_rejects_path_traversal_and_invalid_counts_or_hashes(self) -> None:
        wav_data = make_wav((1, 2), channels=1, sample_rate=reference.SAMPLE_RATE)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "clip.wav").write_bytes(wav_data)
            valid = manifest_clip("clip", "clip.wav", wav_data, 2)
            cases = (
                ({**valid, "file": "../clip.wav"}, "non-basename"),
                ({**valid, "file": "nested/clip.wav"}, "non-basename"),
                ({**valid, "file": r"..\\clip.wav"}, "non-basename"),
                ({**valid, "sample_count": 0}, "positive integer"),
                ({**valid, "sample_count": -1}, "positive integer"),
                ({**valid, "sample_count": True}, "positive integer"),
                ({**valid, "sha256": "a" * 63}, "invalid SHA-256"),
                ({**valid, "sha256": "A" * 64}, "invalid SHA-256"),
            )
            for index, (clip, message) in enumerate(cases):
                with self.subTest(clip=clip):
                    path = write_audio_manifest(root / f"invalid-{index}.json", [clip])
                    with self.assertRaisesRegex(reference.ReferenceError, message):
                        reference.load_audio_manifest(path)

    def test_audio_manifest_requires_exact_schema_and_nonempty_clips(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            invalid_documents = (
                ({"schema_version": 2, "clips": [{}]}, "schema_version"),
                ({"schema_version": 1, "clips": [], "extra": True}, "exactly"),
                ({"schema_version": 1, "clips": []}, "nonempty"),
            )
            for index, (document, message) in enumerate(invalid_documents):
                path = root / f"schema-{index}.json"
                path.write_text(json.dumps(document), encoding="utf-8")
                with self.subTest(document=document):
                    with self.assertRaisesRegex(reference.ReferenceError, message):
                        reference.load_audio_manifest(path)

    def test_audio_manifest_files_are_checked_by_existing_wav_loader(self) -> None:
        stereo_wav = make_wav((1, 2), channels=2, sample_rate=reference.SAMPLE_RATE)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "stereo.wav").write_bytes(stereo_wav)
            manifest = write_audio_manifest(
                root / "clips.json", [manifest_clip("stereo", "stereo.wav", stereo_wav, 2)]
            )
            resolved_directory, clips = reference.load_audio_manifest(manifest)
            with self.assertRaisesRegex(reference.ReferenceError, "mono PCM16"):
                reference.load_clip_samples(resolved_directory, clips[0], FakeNumpy)

    def test_cli_requires_model_manifest_and_language_arguments(self) -> None:
        arguments = [
            "generator",
            "--model-directory", "/model",
            "--output", "/output.json",
            "--model-size", "1.7b",
            "--audio-manifest", "/clips.json",
            "--language-tag", "ja",
        ]
        required_options = ("--model-size", "--audio-manifest", "--language-tag")
        for option in required_options:
            reduced = list(arguments)
            option_index = reduced.index(option)
            del reduced[option_index : option_index + 2]
            with self.subTest(missing=option), mock.patch.object(reference.sys, "argv", reduced):
                with mock.patch("sys.stderr", new_callable=io.StringIO):
                    with mock.patch.object(reference, "generate_reference") as generate_reference:
                        with self.assertRaises(SystemExit) as raised:
                            reference.main()
                self.assertEqual(raised.exception.code, 2)
                generate_reference.assert_not_called()

    def test_cli_forwards_all_arguments_for_both_language_tags(self) -> None:
        cases = (("0.6b", "ja"), ("1.7b", "Japanese"))
        for model_size, language_tag in cases:
            arguments = [
                "generator",
                "--model-directory", "/model",
                "--output", "/output.json",
                "--model-size", model_size,
                "--audio-manifest", "/clips.json",
                "--language-tag", language_tag,
            ]
            with self.subTest(language_tag=language_tag), mock.patch.object(
                reference.sys, "argv", arguments
            ), mock.patch.object(reference, "generate_reference") as generate_reference:
                self.assertEqual(reference.main(), 0)
            generate_reference.assert_called_once_with(
                Path("/model"),
                Path("/output.json"),
                model_size,
                Path("/clips.json"),
                language_tag,
            )

    def test_cli_rejects_invalid_language_tag_before_generation(self) -> None:
        arguments = [
            "generator",
            "--model-directory", "/model",
            "--output", "/output.json",
            "--model-size", "0.6b",
            "--audio-manifest", "/clips.json",
            "--language-tag", "japanese",
        ]
        with mock.patch.object(reference.sys, "argv", arguments), mock.patch(
            "sys.stderr", new_callable=io.StringIO
        ), mock.patch.object(reference, "generate_reference") as generate_reference:
            with self.assertRaises(SystemExit) as raised:
                reference.main()
        self.assertEqual(raised.exception.code, 2)
        generate_reference.assert_not_called()

    def test_cli_rejects_invalid_model_size_before_generation(self) -> None:
        arguments = [
            "generator",
            "--model-directory", "/model",
            "--output", "/output.json",
            "--model-size", "6b",
            "--audio-manifest", "/clips.json",
            "--language-tag", "ja",
        ]
        with mock.patch.object(reference.sys, "argv", arguments), mock.patch(
            "sys.stderr", new_callable=io.StringIO
        ), mock.patch.object(reference, "generate_reference") as generate_reference:
            with self.assertRaises(SystemExit) as raised:
                reference.main()
        self.assertEqual(raised.exception.code, 2)
        generate_reference.assert_not_called()

    def test_cli_returns_one_when_reference_generation_fails(self) -> None:
        arguments = [
            "generator",
            "--model-directory", "/model",
            "--output", "/output.json",
            "--model-size", "1.7b",
            "--audio-manifest", "/clips.json",
            "--language-tag", "Japanese",
        ]
        with mock.patch.object(reference.sys, "argv", arguments), mock.patch(
            "sys.stderr", new_callable=io.StringIO
        ) as stderr, mock.patch.object(
            reference, "generate_reference", side_effect=reference.ReferenceError("failed")
        ) as generate_reference:
            self.assertEqual(reference.main(), 1)
        generate_reference.assert_called_once_with(
            Path("/model"),
            Path("/output.json"),
            "1.7b",
            Path("/clips.json"),
            "Japanese",
        )
        self.assertIn("error: failed", stderr.getvalue())

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
