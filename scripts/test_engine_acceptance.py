#!/usr/bin/env python3
"""Stdlib self-tests for the engine acceptance driver's protocol logic."""

from __future__ import annotations

import json
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

import engine_acceptance as acceptance


def _bare_child() -> acceptance.EngineChild:
    child = acceptance.EngineChild.__new__(acceptance.EngineChild)
    child.last_sequence = 0
    child.ready_seen = False
    child.requests = {}
    child.protocol_failure_expected = False
    child.protocol_failure_count = 0
    child.thread_errors = []
    child.thread_error_lock = threading.Lock()
    child.stderr_tail = bytearray()
    child.stderr_lock = threading.Lock()
    return child


def _envelope(sequence: str, event: str, request_id: str | None, payload: dict[str, object]) -> bytes:
    import json

    return json.dumps(
        {
            "version": 1,
            "sequence": sequence,
            "request_id": request_id,
            "event": event,
            "payload": payload,
        },
        separators=(",", ":"),
    ).encode("utf-8")


class ExtendedWindowsPathTests(unittest.TestCase):
    def test_drive_path_gets_extended_prefix(self) -> None:
        self.assertEqual(
            acceptance._extended_path_spelling(r"C:\acceptance root\fixture.wav", windows=True),
            r"\\?\C:\acceptance root\fixture.wav",
        )

    def test_unc_path_gets_extended_unc_prefix(self) -> None:
        self.assertEqual(
            acceptance._extended_path_spelling(r"\\server\share\acceptance root", windows=True),
            r"\\?\UNC\server\share\acceptance root",
        )

    def test_already_extended_drive_path_is_unchanged(self) -> None:
        path = r"\\?\C:\acceptance root\fixture.wav"
        self.assertEqual(acceptance._extended_path_spelling(path, windows=True), path)

    def test_already_extended_unc_path_is_unchanged(self) -> None:
        path = r"\\?\UNC\server\share\acceptance root"
        self.assertEqual(acceptance._extended_path_spelling(path, windows=True), path)

    def test_relative_path_is_rejected(self) -> None:
        with self.assertRaisesRegex(acceptance.AcceptanceError, "must be absolute"):
            acceptance._extended_path_spelling(r"relative\fixture.wav", windows=True)

    def test_foundation_windows_path_normalizes_separators(self) -> None:
        self.assertEqual(
            acceptance._extended_path_spelling("//?/C:/acceptance root/bundle", windows=True),
            r"\\?\C:\acceptance root\bundle",
        )
        self.assertEqual(
            acceptance._extended_path_spelling("C:/acceptance root/bundle", windows=True),
            r"\\?\C:\acceptance root\bundle",
        )

    def test_posix_path_spelling_is_unchanged(self) -> None:
        path = "/tmp/acceptance fixture.wav"
        self.assertEqual(acceptance._extended_path_spelling(path, windows=False), path)


class StrictJSONTests(unittest.TestCase):
    def test_duplicate_object_keys_are_rejected(self) -> None:
        with self.assertRaisesRegex(acceptance.AcceptanceError, "duplicate JSON object key"):
            acceptance.strict_json(b'{"value":1,"value":2}', "duplicate test")

    def test_nonstandard_json_constants_are_rejected(self) -> None:
        with self.assertRaisesRegex(acceptance.AcceptanceError, "non-standard JSON numeric constant"):
            acceptance.strict_json(b'{"value":NaN}', "constant test")

    def test_overflowing_json_number_is_rejected(self) -> None:
        with self.assertRaisesRegex(acceptance.AcceptanceError, "non-finite JSON number"):
            acceptance.strict_json(b'{"nested":[1e999]}', "overflow test")

    def test_invalid_utf8_is_rejected(self) -> None:
        with self.assertRaisesRegex(acceptance.AcceptanceError, "invalid UTF-8"):
            acceptance.strict_json(b"\xff", "UTF-8 test")


class EnvelopeAndRequestTests(unittest.TestCase):
    def test_sequence_must_increase_strictly(self) -> None:
        child = _bare_child()
        child._dispatch(_envelope("1", "ready", None, {}), "ready")
        with self.assertRaisesRegex(acceptance.AcceptanceError, "not strictly greater"):
            child._dispatch(_envelope("1", "state", None, {}), "duplicate sequence")

    def test_expected_error_request_has_one_terminal_event(self) -> None:
        child = _bare_child()
        child.requests["7"] = {
            "command": "session.export",
            "accepted": 0,
            "terminal": 0,
            "result": None,
            "error": None,
            "expected_error_code": "export_failure",
        }
        child._dispatch(_envelope("1", "ready", None, {}), "ready")
        child._dispatch(_envelope("2", "accepted", "7", {"command": "session.export"}), "accepted")
        error_payload = {"request_id": "7", "code": "export_failure"}
        child._dispatch(_envelope("3", "error", "7", error_payload), "expected error")
        self.assertEqual(child.requests["7"]["terminal"], 1)
        self.assertEqual(child.requests["7"]["error"], error_payload)
        child.verify_request_registry()
        with self.assertRaisesRegex(acceptance.AcceptanceError, "expected error must follow one accepted event"):
            child._dispatch(_envelope("4", "error", "7", error_payload), "duplicate error")
        self.assertEqual(child.requests["7"]["terminal"], 1)

    def test_expected_error_code_must_match(self) -> None:
        child = _bare_child()
        child.requests["2"] = {
            "command": "session.export",
            "accepted": 0,
            "terminal": 0,
            "result": None,
            "error": None,
            "expected_error_code": "export_failure",
        }
        child._dispatch(_envelope("1", "ready", None, {}), "ready")
        child._dispatch(_envelope("2", "accepted", "2", {"command": "session.export"}), "accepted")
        with self.assertRaisesRegex(acceptance.AcceptanceError, "expected error code 'export_failure'"):
            child._dispatch(
                _envelope("3", "error", "2", {"request_id": "2", "code": "filesystem"}),
                "wrong error",
            )

    def test_expected_error_code_accepts_platform_filesystem_mapping(self) -> None:
        child = _bare_child()
        child.requests["3"] = {
            "command": "session.export",
            "accepted": 0,
            "terminal": 0,
            "result": None,
            "error": None,
            "expected_error_code": ("export_failure", "filesystem"),
        }
        child._dispatch(_envelope("1", "ready", None, {}), "ready")
        child._dispatch(_envelope("2", "accepted", "3", {"command": "session.export"}), "accepted")
        error_payload = {"request_id": "3", "code": "filesystem"}
        child._dispatch(_envelope("3", "error", "3", error_payload), "expected filesystem mapping")
        self.assertEqual(child.requests["3"]["accepted"], 1)
        self.assertEqual(child.requests["3"]["terminal"], 1)
        self.assertEqual(child.requests["3"]["error"], error_payload)
        child.verify_request_registry()


class PCMValidationTests(unittest.TestCase):
    def test_short_pcm_prefix_reports_missing_sample_without_index_error(self) -> None:
        decoded = {
            "sample_rate": 16_000,
            "channels": 1,
            "bits_per_sample": 16,
            "samples": [8_192],
            "sample_count": 1,
            "frame_count": 1,
        }
        with patch.object(acceptance, "validate_flac", return_value=decoded):
            with self.assertRaisesRegex(
                acceptance.AcceptanceError,
                r"actual_frames=1 first_mismatch=\(1, 8192, None\)",
            ):
                acceptance._validate_flac_file(
                    Path("mock.flac"),
                    2,
                    16_000,
                    "short fixture",
                    expected_samples=[8_192, 8_192],
                )

    def test_extra_recovered_tail_reports_first_extra_sample(self) -> None:
        decoded = {
            "sample_rate": 16_000,
            "channels": 1,
            "bits_per_sample": 16,
            "samples": [1, 2, 3],
            "sample_count": 3,
            "frame_count": 1,
        }
        with patch.object(acceptance, "validate_flac", return_value=decoded):
            with self.assertRaisesRegex(
                acceptance.AcceptanceError,
                r"expected_frames=2 actual_frames=3 first_mismatch=\(2, None, 3\)",
            ):
                acceptance._validate_flac_file(
                    Path("mock-extra-tail.flac"),
                    3,
                    16_000,
                    "extra-tail fixture",
                    expected_samples=[1, 2],
                )


def _flac_summary(samples: list[int]) -> dict[str, object]:
    return {
        "sample_rate": 16_000,
        "channels": 1,
        "bits_per_sample": 16,
        "samples": samples,
        "sample_count": len(samples),
        "frame_count": (len(samples) + 4_095) // 4_096,
        "md5": "mock-md5",
    }


class RampFixtureAndValidationTests(unittest.TestCase):
    def test_fixture_has_distinct_strictly_increasing_channel_ramps(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            owner = Path(temporary)
            for rate in (16_000, 44_100, 48_000):
                for channels in (2, 3):
                    with self.subTest(rate=rate, channels=channels):
                        path = owner / f"fixture-{rate}-{channels}.f32le"
                        source_frames = acceptance.create_fixture(path, rate, channels)
                        self.assertEqual(source_frames, rate * 2 + 1_000)
                        data = path.read_bytes()
                        self.assertEqual(len(data), source_frames * channels * 4)
                        values = struct.unpack("<" + "f" * (source_frames * channels), data)
                        offsets = (-0.125, 0.125) if channels == 2 else (-0.125, 0.0, 0.125)
                        previous: list[float | None] = [None] * channels
                        for frame in range(source_frames):
                            base = (-16_000 + frame * 16_000 / rate) / 32_768
                            frame_values = values[frame * channels : (frame + 1) * channels]
                            self.assertEqual(len(set(frame_values)), channels)
                            for channel, offset in enumerate(offsets):
                                expected = struct.unpack("<f", struct.pack("<f", base + offset))[0]
                                actual = frame_values[channel]
                                self.assertEqual(actual, expected)
                                self.assertLess(abs(actual), 1.0, "fixture must not clip")
                                if previous[channel] is not None:
                                    self.assertGreater(actual, previous[channel])
                                previous[channel] = actual

    def test_fixture_rejects_unsupported_rate_and_channel_count(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            owner = Path(temporary)
            with self.assertRaisesRegex(acceptance.AcceptanceError, "does not support sample rate 32000"):
                acceptance.create_fixture(owner / "unsupported-rate.f32le", 32_000, 2)
            with self.assertRaisesRegex(acceptance.AcceptanceError, "does not support 4 channels"):
                acceptance.create_fixture(owner / "unsupported-channels.f32le", 16_000, 4)

    def test_identity_pcm_matches_every_global_frame_including_endpoints(self) -> None:
        source_frames = 16_000 * 2 + 1_000
        samples = [index - 16_000 for index in range(source_frames)]
        self.assertEqual(samples[0], -16_000)
        self.assertEqual(samples[-1], source_frames - 1 - 16_000)
        acceptance._verify_sample_values(samples, source_frames, 16_000, "identity analytic ramp")
        with patch.object(acceptance, "validate_flac", return_value=_flac_summary(samples)):
            result = acceptance._validate_flac_file(
                Path("mock-identity.flac"), source_frames, 16_000, "identity full FLAC"
            )
        self.assertEqual(result["samples"], samples)

    def test_identity_pcm_rejects_first_and_last_sample_corruption(self) -> None:
        source_frames = 16_000 * 2 + 1_000
        analytic_samples = [index - 16_000 for index in range(source_frames)]
        for index in (0, source_frames - 1):
            with self.subTest(index=index):
                corrupted = analytic_samples.copy()
                corrupted[index] += 1
                with patch.object(acceptance, "validate_flac", return_value=_flac_summary(corrupted)):
                    with self.assertRaisesRegex(acceptance.AcceptanceError, f"identity PCM sample {index}"):
                        acceptance._validate_flac_file(
                            Path(f"mock-identity-endpoint-{index}.flac"),
                            source_frames,
                            16_000,
                            "identity endpoint corruption",
                        )

    def test_src_rates_accept_independent_analytic_ramp(self) -> None:
        for rate in (44_100, 48_000):
            with self.subTest(rate=rate):
                source_frames = rate * 2 + 1_000
                sample_count = source_frames * 16_000 // rate
                analytic_samples = [index - 16_000 for index in range(sample_count)]
                with patch.object(acceptance, "validate_flac", return_value=_flac_summary(analytic_samples)):
                    result = acceptance._validate_flac_file(
                        Path(f"mock-{rate}.flac"), source_frames, rate, f"{rate} Hz analytic SRC"
                    )
                self.assertEqual(result["samples"], analytic_samples)

    def test_src_rates_accept_eight_lsb_and_reject_nine_lsb_at_interior_sample(self) -> None:
        for rate in (44_100, 48_000):
            with self.subTest(rate=rate):
                source_frames = rate * 2 + 1_000
                sample_count = source_frames * 16_000 // rate
                analytic_samples = [index - 16_000 for index in range(sample_count)]
                for delta, should_accept in ((8, True), (9, False)):
                    with self.subTest(delta=delta):
                        samples = analytic_samples.copy()
                        samples[4_096] += delta
                        with patch.object(acceptance, "validate_flac", return_value=_flac_summary(samples)):
                            if should_accept:
                                result = acceptance._validate_flac_file(
                                    Path(f"mock-{rate}-plus-{delta}.flac"),
                                    source_frames,
                                    rate,
                                    f"{rate} Hz SRC tolerance boundary",
                                )
                                self.assertEqual(result["samples"], samples)
                            else:
                                with self.assertRaisesRegex(
                                    acceptance.AcceptanceError, "interior SRC sample 4096"
                                ):
                                    acceptance._validate_flac_file(
                                        Path(f"mock-{rate}-plus-{delta}.flac"),
                                        source_frames,
                                        rate,
                                        f"{rate} Hz SRC tolerance boundary",
                                    )

    def test_input_ignoring_constant_and_zero_are_rejected_at_all_rates(self) -> None:
        for rate in (16_000, 44_100, 48_000):
            source_frames = rate * 2 + 1_000
            quotient, remainder = divmod(source_frames * 16_000, rate)
            sample_count = source_frames if rate == 16_000 else quotient
            self.assertIn(sample_count, {quotient, quotient + (1 if remainder else 0)})
            for constant in (8_192, 0):
                with self.subTest(rate=rate, constant=constant):
                    samples = [constant] * sample_count
                    with patch.object(acceptance, "validate_flac", return_value=_flac_summary(samples)):
                        with self.assertRaisesRegex(
                            acceptance.AcceptanceError, "(?:identity PCM sample|interior SRC sample)"
                        ):
                            acceptance._validate_flac_file(
                                Path(f"mock-constant-{rate}.flac"),
                                source_frames,
                                rate,
                                f"{rate} Hz constant rejection",
                            )

    def test_full_flac_validation_rejects_reordered_and_duplicated_same_length_chunks(self) -> None:
        chunk_size = 512
        first_chunk = 4_096
        second_chunk = 8_192
        for rate in (16_000, 44_100, 48_000):
            with self.subTest(rate=rate):
                source_frames = rate * 2 + 1_000
                sample_count = source_frames * 16_000 // rate
                analytic = [index - 16_000 for index in range(sample_count)]
                swapped = analytic.copy()
                swapped[first_chunk : first_chunk + chunk_size], swapped[second_chunk : second_chunk + chunk_size] = (
                    swapped[second_chunk : second_chunk + chunk_size],
                    swapped[first_chunk : first_chunk + chunk_size],
                )
                duplicated = analytic.copy()
                duplicated[first_chunk : first_chunk + chunk_size] = duplicated[
                    second_chunk : second_chunk + chunk_size
                ]
                self.assertEqual(len(swapped), len(analytic))
                self.assertEqual(len(duplicated), len(analytic))
                self.assertEqual(
                    swapped[first_chunk : first_chunk + chunk_size],
                    analytic[second_chunk : second_chunk + chunk_size],
                )
                self.assertEqual(
                    duplicated[first_chunk : first_chunk + chunk_size],
                    analytic[second_chunk : second_chunk + chunk_size],
                )

                mismatch = (
                    f"identity PCM sample {first_chunk}"
                    if rate == 16_000
                    else f"interior SRC sample {first_chunk}"
                )
                for name, samples in (("reordered", swapped), ("duplicated", duplicated)):
                    with self.subTest(mutation=name):
                        with patch.object(acceptance, "validate_flac", return_value=_flac_summary(samples)):
                            with self.assertRaisesRegex(acceptance.AcceptanceError, mismatch):
                                acceptance._validate_flac_file(
                                    Path(f"mock-{rate}-{name}.flac"),
                                    source_frames,
                                    rate,
                                    f"{rate} Hz {name} same-length FLAC",
                                )

                            if rate == 16_000:
                                with self.assertRaisesRegex(
                                    acceptance.AcceptanceError, "PCM differs from the committed prefix"
                                ):
                                    acceptance._validate_flac_file(
                                        Path(f"mock-{rate}-{name}-committed-prefix.flac"),
                                        source_frames,
                                        rate,
                                        f"{rate} Hz {name} committed prefix",
                                        expected_samples=analytic,
                                    )

    def _write_checkpoint(
        self,
        session_dir: Path,
        chunk_order: list[int],
        duplicate: tuple[int, int] | None,
    ) -> tuple[Path, list[Path]]:
        processing = session_dir / "audio" / "processing"
        processing.mkdir(parents=True)
        chunk_size = 512
        chunk_paths: list[Path] = []
        for chunk_index in range(16):
            first_frame = chunk_index * chunk_size
            values = [(frame - 16_000) / 32_768 for frame in range(first_frame, first_frame + chunk_size)]
            path = processing / f"chunk-{chunk_index:02d}.f32le"
            path.write_bytes(struct.pack("<" + "f" * chunk_size, *values))
            chunk_paths.append(path)
        if duplicate is not None:
            target, source = duplicate
            chunk_paths[target].write_bytes(chunk_paths[source].read_bytes())
        checkpoint = {
            "committedFrames": 8_192,
            "sampleRate": 16_000,
            "channelCount": 1,
            "sampleFormat": "float32",
            "chunkFiles": [chunk_paths[index].name for index in chunk_order],
            "chunkFrameCounts": [chunk_size] * len(chunk_order),
            "gapEvents": [],
        }
        (processing / "checkpoint.json").write_text(json.dumps(checkpoint), encoding="utf-8")
        return processing, chunk_paths

    def test_checkpoint_validates_global_ramp_and_exact_chunk_snapshots(self) -> None:
        committed = 8_192
        with tempfile.TemporaryDirectory() as temporary:
            session_dir = Path(temporary)
            processing, chunk_paths = self._write_checkpoint(session_dir, list(range(16)), None)
            frame_count, snapshots, expected = acceptance._validate_checkpoint(session_dir, 33_000)
            written_snapshots = [path.read_bytes() for path in chunk_paths]
        self.assertEqual(frame_count, committed)
        self.assertEqual(len(snapshots), 16)
        self.assertEqual(snapshots, written_snapshots)
        self.assertEqual(expected, [index - 16_000 for index in range(committed)])
        self.assertEqual(processing.name, "processing")

    def test_checkpoint_rejects_reordered_and_duplicated_512_sample_chunks(self) -> None:
        for mutation in ("reordered", "duplicated"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                session_dir = Path(temporary)
                order = list(range(16))
                duplicate = None
                if mutation == "reordered":
                    order[4], order[8] = order[8], order[4]
                else:
                    duplicate = (4, 8)
                processing, chunk_paths = self._write_checkpoint(session_dir, order, duplicate)
                self.assertEqual(chunk_paths[4].stat().st_size, 512 * 4)
                self.assertEqual(chunk_paths[8].stat().st_size, 512 * 4)
                with self.assertRaisesRegex(acceptance.AcceptanceError, "global frame"):
                    acceptance._validate_checkpoint(session_dir, 33_000)
                self.assertTrue((processing / "checkpoint.json").is_file())

    def test_folder_id_is_required_and_must_be_nonempty_text(self) -> None:
        self.assertEqual(acceptance._required_folder_id({"folder_id": "session-1"}, "test catalog"), "session-1")
        with self.assertRaisesRegex(acceptance.AcceptanceError, "test catalog.*missing folder_id"):
            acceptance._required_folder_id({}, "test catalog")
        for value in (None, 4, "", []):
            with self.subTest(value=value):
                with self.assertRaisesRegex(acceptance.AcceptanceError, "nonempty string"):
                    acceptance._required_folder_id({"folder_id": value}, "test catalog")


class RawSendDeadlineTests(unittest.TestCase):
    def test_blocked_raw_send_times_out_kills_child_and_joins_writer(self) -> None:
        process = subprocess.Popen(
            [sys.executable, "-c", "import time; time.sleep(60)"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
        )
        if process.stdin is None or process.stdout is None or process.stderr is None:
            process.kill()
            process.wait(timeout=5)
            self.fail("fake child pipes were not created")
        child = _bare_child()
        child.process = process
        child.stdin = process.stdin
        child.input_closed = False
        child.deadline = time.monotonic() + 10
        child.write_thread = None
        try:
            with patch.object(acceptance, "STDIO_TIMEOUT_SECONDS", 0.15):
                with self.assertRaisesRegex(acceptance.AcceptanceError, "stdin write exceeded 0.15s deadline"):
                    child.send_raw(b"x" * (2 * 1024 * 1024), context="blocked-write self-test")
            self.assertIsNotNone(process.poll(), "timed-out writer did not kill and reap its child")
            self.assertIsNotNone(child.write_thread)
            self.assertFalse(child.write_thread.is_alive(), "timed-out writer thread leaked")
            self.assertFalse(
                any(thread.name == "engine-acceptance-input-writer" and thread.is_alive()
                    for thread in threading.enumerate()),
                "an acceptance input writer remains alive",
            )
        finally:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=5)
            process.stdout.close()
            process.stderr.close()
            if child.write_thread is not None and child.write_thread.is_alive():
                child.write_thread.join(timeout=2)

    def test_close_reports_child_reap_timeout(self) -> None:
        child = acceptance.EngineChild.__new__(acceptance.EngineChild)
        child.closed = False
        child.process = Mock()
        child.process.poll.return_value = None
        child.process.wait.side_effect = subprocess.TimeoutExpired("fake-engine", 30)
        child.close_stdin = Mock()
        child.stop_threads = threading.Event()
        child.stdout = Mock()
        child.stderr = Mock()
        child.stdout_thread = Mock(name="stdout-thread")
        child.stdout_thread.is_alive.return_value = False
        child.stderr_thread = Mock(name="stderr-thread")
        child.stderr_thread.is_alive.return_value = False
        child.write_thread = None
        with self.assertRaisesRegex(acceptance.AcceptanceError, "engine child was not reaped"):
            child.close()
        child.process.wait.assert_called_once_with(timeout=acceptance.STDIO_TIMEOUT_SECONDS)

    def test_context_exit_preserves_original_failure_with_cleanup_context(self) -> None:
        child = acceptance.EngineChild.__new__(acceptance.EngineChild)
        child.close = Mock(side_effect=acceptance.AcceptanceError("reap timeout"))
        original = acceptance.AcceptanceError("send deadline")
        with self.assertRaisesRegex(acceptance.AcceptanceError, "send deadline; cleanup also failed: reap timeout") as caught:
            child.__exit__(acceptance.AcceptanceError, original, None)
        self.assertIs(caught.exception.__cause__, original)


if __name__ == "__main__":
    unittest.main(verbosity=2)
