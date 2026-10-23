#!/usr/bin/env python3
"""Stdlib self-tests for the engine acceptance driver's protocol logic."""

from __future__ import annotations

import contextlib
import io
import json
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import wave
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
    child.stdio_timeout = acceptance.STDIO_TIMEOUT_SECONDS
    child.scenario_timeout = acceptance.SCENARIO_TIMEOUT_SECONDS
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


class ProcessRecordingPathTests(unittest.TestCase):
    def test_drive_paths_use_ordinary_spelling_from_both_forms(self) -> None:
        expected = r"C:\acceptance root\fixture.wav"
        self.assertEqual(acceptance._process_recording_path(Path(expected), windows=True), expected)
        self.assertEqual(
            acceptance._process_recording_path(Path(r"\\?\C:\acceptance root\fixture.wav"), windows=True),
            expected,
        )

    def test_unc_paths_use_ordinary_spelling_from_both_forms(self) -> None:
        expected = r"\\server\share\acceptance root"
        self.assertEqual(acceptance._process_recording_path(Path(expected), windows=True), expected)
        self.assertEqual(
            acceptance._process_recording_path(Path(r"\\?\UNC\server\share\acceptance root"), windows=True),
            expected,
        )

    def test_command_argv_uses_ordinary_spelling_for_each_windows_path(self) -> None:
        process_recording = Path(r"C:\tools\ProcessRecording.exe")
        baseline = acceptance._baseline_process_recording_command(
            process_recording,
            Path(r"\\?\C:\acceptance\baseline-sessions"),
            Path(r"\\?\C:\acceptance\source.wav"),
            Path(r"\\?\C:\acceptance\baseline.json"),
            2,
            windows=True,
        )
        self.assertEqual(
            baseline,
            [
                str(process_recording), "--sessions-root", r"C:\acceptance\baseline-sessions",
                "--keep-session", "--with-decisions", "--threads", "2",
                r"C:\acceptance\source.wav", r"C:\acceptance\baseline.json",
            ],
        )
        host = acceptance._host_resume_process_recording_command(
            process_recording,
            "session-1",
            Path(r"\\?\UNC\server\share\sessions"),
            Path(r"\\?\UNC\server\share\host.json"),
            2,
            windows=True,
        )
        self.assertEqual(
            host,
            [
                str(process_recording), "--resume-session", "session-1", "--sessions-root",
                r"\\server\share\sessions", "--with-decisions", "--threads", "2",
                r"\\server\share\host.json",
            ],
        )

    def test_posix_path_is_unchanged(self) -> None:
        path = Path("/tmp/acceptance fixture.wav")
        self.assertEqual(acceptance._process_recording_path(path, windows=False), str(path))

    def test_unsupported_windows_namespaces_are_rejected(self) -> None:
        for path in (
            r"\\.\C:\fixture.wav",
            r"\\?\Volume{12345678-1234-1234-1234-123456789012}\fixture.wav",
            r"\\?\GLOBALROOT\Device\HarddiskVolume1\fixture.wav",
        ):
            with self.subTest(path=path), self.assertRaisesRegex(
                acceptance.AcceptanceError, "unsupported Windows path namespace"
            ):
                acceptance._process_recording_path(Path(path), windows=True)

    def test_relative_and_dot_component_paths_are_rejected(self) -> None:
        for path in (r"relative\fixture.wav", r"C:\acceptance\..\fixture.wav", r"\\?\C:\acceptance\.\fixture.wav"):
            with self.subTest(path=path), self.assertRaises(acceptance.AcceptanceError):
                acceptance._process_recording_path(path, windows=True)


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
    def test_engine_launch_passes_explicit_inference_and_threads(self) -> None:
        process = Mock()
        process.stdin = Mock()
        process.stdout = Mock()
        process.stderr = Mock()
        with (
            patch.object(acceptance.subprocess, "Popen", return_value=process) as popen,
            patch.object(acceptance.threading, "Thread", side_effect=[Mock(), Mock()]),
        ):
            acceptance.EngineChild(
                Path("engine"), Path("root"), Path("fixture.f32le"), 48_000, 2,
                inference="portable", threads=3, scenario_timeout=10, stdio_timeout=2,
            )
        argv = popen.call_args.args[0]
        self.assertEqual(argv[1:5], ["--inference", "portable", "--threads", "3"])

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
            with patch.object(child, "stdio_timeout", 0.15):
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
        child.stdio_timeout = acceptance.STDIO_TIMEOUT_SECONDS
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


def _speech_segment() -> dict[str, object]:
    return {
        "segment_id": "segment-1",
        "source": {
            "segmentation_run_id": "seg-uuid-a",
            "segment_id": "segment-1",
            "asr_run_id": "asr-uuid-a",
            "asr_event_seq": 17,
        },
        "start_ms": 100,
        "end_ms": 900,
        "text": "これは日本語です。",
        "display_text": "これは日本語です。",
        "speakers": [{"id": "speaker-1", "start_ms": 100, "end_ms": 900, "confidence": 0.91}],
        "clause_state": "classified",
        "clause_slices": [{
            "reference": {"boundary_run_id": "boundary-uuid-a", "clause_id": "clause-a"},
            "source_range": {"start": 0, "end": 9},
            "priority": "primary",
            "needs_retry": False,
        }],
    }


def _clone(value: object) -> object:
    return json.loads(json.dumps(value))


class FullModelInputTests(unittest.TestCase):
    def test_subcommands_and_every_required_flag(self) -> None:
        parser = acceptance.build_parser()
        invalid_arguments = [
            [],
            ["deterministic"],
            ["full-model"],
            ["full-model", "--executable", "engine"],
            ["full-model", "--executable", "engine", "--process-recording", "cli"],
            ["full-model", "--executable", "engine", "--process-recording", "cli", "--fixture", "fixture.wav"],
        ]
        for arguments in invalid_arguments:
            with self.subTest(arguments=arguments), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit):
                    parser.parse_args(arguments)
        parsed = parser.parse_args(["deterministic", "--executable", "engine"])
        self.assertEqual(parsed.command, "deterministic")
        parsed = parser.parse_args([
            "full-model", "--executable", "engine", "--process-recording", "cli",
            "--fixture", "fixture.wav", "--threads", "2",
        ])
        self.assertEqual(parsed.command, "full-model")
        self.assertEqual(parsed.threads, 2)

    def test_invalid_threads_are_rejected(self) -> None:
        parser = acceptance.build_parser()
        prefix = [
            "full-model", "--executable", "engine", "--process-recording", "cli",
            "--fixture", "fixture.wav", "--threads",
        ]
        for invalid in ("0", "-1", "+2", "many"):
            with self.subTest(value=invalid), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit):
                    parser.parse_args([*prefix, invalid])

    def test_full_model_rejects_macos_before_environment_or_path_checks(self) -> None:
        with patch.object(acceptance.sys, "platform", "darwin"):
            with self.assertRaisesRegex(acceptance.AcceptanceError, "unavailable on darwin"):
                acceptance.run_full_model(
                    Path("missing-engine"), Path("missing-process-recording"), Path("missing-fixture.wav"), 1
                )

    def test_model_environment_is_required(self) -> None:
        helper = acceptance._load_process_recording_acceptance()
        with self.assertRaisesRegex(helper.AcceptanceFailure, "MAC_AMBIENT_JEV_SILERO_MODEL is required"):
            helper.require_model_environment({})

    def test_pcm16_conversion_is_exact_and_windows_upsampling_repeats_samples(self) -> None:
        samples = [-32_768, -1, 0, 32_767]
        with tempfile.TemporaryDirectory() as temporary:
            owner = Path(temporary)
            fixture = owner / "source.wav"
            with wave.open(str(fixture), "wb") as audio:
                audio.setnchannels(1)
                audio.setsampwidth(2)
                audio.setframerate(16_000)
                audio.writeframes(struct.pack("<4h", *samples))

            f32_16 = owner / "canonical.f32le"
            wav_16 = owner / "canonical.wav"
            frames_16 = acceptance._write_speech_inputs(
                fixture, f32_16, wav_16, rate=16_000, channels=1
            )
            self.assertEqual(frames_16, len(samples))
            expected_float = struct.pack("<4f", *(sample / 32_768 for sample in samples))
            self.assertEqual(f32_16.read_bytes(), expected_float)
            with wave.open(str(wav_16), "rb") as audio:
                self.assertEqual((audio.getframerate(), audio.getnchannels(), audio.getsampwidth()), (16_000, 1, 2))
                self.assertEqual(audio.readframes(100), struct.pack("<4h", *samples))

            f32_48 = owner / "upsampled.f32le"
            wav_48 = owner / "upsampled.wav"
            frames_48 = acceptance._write_speech_inputs(
                fixture, f32_48, wav_48, rate=48_000, channels=2
            )
            repeated = [sample for sample in samples for _ in range(3) for _channel in range(2)]
            self.assertEqual(frames_48, len(samples) * 3)
            self.assertEqual(f32_48.read_bytes(), struct.pack("<" + "f" * len(repeated), *(v / 32_768 for v in repeated)))
            with wave.open(str(wav_48), "rb") as audio:
                self.assertEqual((audio.getframerate(), audio.getnchannels(), audio.getsampwidth()), (48_000, 2, 2))
                self.assertEqual(audio.readframes(100), struct.pack("<" + "h" * len(repeated), *repeated))


class SemanticComparisonTests(unittest.TestCase):
    def test_unknown_published_segment_key_is_rejected(self) -> None:
        segment = _speech_segment()
        segment["unexpected"] = "not part of the schema"
        with self.assertRaisesRegex(acceptance.AcceptanceError, "explicit materialized-segment schema"):
            acceptance.normalize_published_segments([segment])

    def test_source_segment_id_must_match_published_segment_id(self) -> None:
        segment = _speech_segment()
        segment["source"]["segment_id"] = "different-segment"
        with self.assertRaisesRegex(acceptance.AcceptanceError, "source.segment_id must match"):
            acceptance.normalize_published_segments([segment])

    def test_multiple_segmentation_asr_or_boundary_runs_are_rejected(self) -> None:
        for field, label in (
            ("segmentation_run_id", "segmentation"),
            ("asr_run_id", "ASR"),
        ):
            with self.subTest(run=label):
                second = _clone(_speech_segment())
                second["segment_id"] = "segment-2"
                second["source"]["segment_id"] = "segment-2"
                second["source"][field] = f"second-{field}"
                with self.assertRaisesRegex(acceptance.AcceptanceError, "exactly one active segmentation, ASR, and boundary run"):
                    acceptance.normalize_published_segments([_speech_segment(), second])

        second = _clone(_speech_segment())
        second["segment_id"] = "segment-2"
        second["source"]["segment_id"] = "segment-2"
        second["clause_slices"][0]["reference"]["boundary_run_id"] = "boundary-run-b"
        with self.assertRaisesRegex(acceptance.AcceptanceError, "exactly one active segmentation, ASR, and boundary run"):
            acceptance.normalize_published_segments([_speech_segment(), second])

    def test_clause_aliasing_does_not_merge_distinct_host_clauses(self) -> None:
        baseline = _speech_segment()
        baseline["clause_slices"].append(_clone(baseline["clause_slices"][0]))
        host = _clone(baseline)
        host["clause_slices"][1]["reference"]["clause_id"] = "host-distinct-clause"
        with self.assertRaisesRegex(
            acceptance.AcceptanceError,
            r"field_mismatches=1 text_mismatches=0 first_differing_field=segments\[0\]\.clause_slices\[1\]\.reference\.clause_id",
        ):
            acceptance.compare_published_segments([baseline], [host])

    def test_semantic_failure_reports_text_mismatches(self) -> None:
        host = _clone(_speech_segment())
        host["text"] = "different text"
        with self.assertRaisesRegex(
            acceptance.AcceptanceError,
            r"segment_mismatches=1 field_mismatches=1 text_mismatches=1 first_differing_field=",
        ):
            acceptance.compare_published_segments([_speech_segment()], [host])

    def test_only_explicit_run_event_and_derived_clause_identity_is_excluded(self) -> None:
        baseline = [_speech_segment()]
        host = [_clone(baseline[0])]
        host_segment = host[0]
        host_segment["source"].update({
            "segmentation_run_id": "seg-uuid-b", "asr_run_id": "asr-uuid-b", "asr_event_seq": 82,
        })
        host_segment["clause_slices"][0]["reference"].update({
            "boundary_run_id": "boundary-uuid-b", "clause_id": "clause-derived-elsewhere",
        })
        self.assertEqual(acceptance.compare_published_segments(baseline, host), {
            "segment_count": 1, "segment_mismatches": 0, "text_mismatches": 0,
            "semantic_fields": acceptance._compared_semantic_field_count(
                acceptance.normalize_published_segments(baseline)
            ),
        })
        self.assertEqual(baseline[0]["segment_id"], host_segment["segment_id"])
        self.assertEqual(len(acceptance.EXCLUDED_LINEAGE_FIELDS), 5)

    def test_text_timing_speaker_confidence_and_decision_drift_are_rejected(self) -> None:
        mutations = {
            "raw text": ("text", "changed text"),
            "display text": ("display_text", "changed display"),
            "timing": ("start_ms", 101),
        }
        for label, (field, value) in mutations.items():
            with self.subTest(field=label):
                host_segment = _clone(_speech_segment())
                host_segment[field] = value
                with self.assertRaisesRegex(acceptance.AcceptanceError, "first_differing_field"):
                    acceptance.compare_published_segments([_speech_segment()], [host_segment])

        for label, mutate in (
            ("speaker identity", lambda segment: segment["speakers"][0].update(id="speaker-2")),
            ("speaker timing", lambda segment: segment["speakers"][0].update(end_ms=899)),
            ("speaker confidence", lambda segment: segment["speakers"][0].update(confidence=0.90)),
            ("decision priority", lambda segment: segment["clause_slices"][0].update(priority="low_priority")),
            ("decision state", lambda segment: segment.update(clause_state="priority_pending")),
        ):
            with self.subTest(field=label):
                host_segment = _clone(_speech_segment())
                mutate(host_segment)
                with self.assertRaisesRegex(acceptance.AcceptanceError, "first_differing_field"):
                    acceptance.compare_published_segments([_speech_segment()], [host_segment])


if __name__ == "__main__":
    unittest.main(verbosity=2)
