#!/usr/bin/env python3
"""Black-box acceptance driver for MacAmbientJevEngineHarness."""

from __future__ import annotations

import json
import math
import os
import queue
import struct
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path, PureWindowsPath
from typing import Any

from engine_acceptance_flac import validate_flac


MAX_RECORD_BYTES = 1_048_576
MAX_STDERR_BYTES = 65_536
STDIO_TIMEOUT_SECONDS = 30.0
SCENARIO_TIMEOUT_SECONDS = 240.0
FINALIZATION_TIMEOUT_SECONDS = 180.0
TRANSCRIPT_TEXT = "エンジンの受け入れテストです。"
TRANSCRIPT_FILE = "[00:00] Speaker 1: エンジンの受け入れテストです。\n"
EXPECTED_SETTINGS: dict[str, Any] = {
    "schema_version": 1,
    "source": "microphone",
    "device": {"kind": "default"},
    "asr_size": "0.6b",
    "execution_provider": "cpu",
    "threads": 1,
    "low_heat": False,
    "decisions_enabled": False,
    "automatic_export": False,
    "export_destination_path": None,
}
EXPECTED_PROVENANCE = {
    "segmentation": "engine-e2e-vad",
    "asr": "engine-e2e-asr",
    "diarization": "engine-e2e-diarization",
}
_EOF = object()


class AcceptanceError(RuntimeError):
    """A useful, fail-fast acceptance mismatch."""


def _extended_path_spelling(path: str | os.PathLike[str], *, windows: bool | None = None) -> str:
    """Return a canonical absolute path spelling, using Win32 extended syntax on Windows."""
    spelling = os.fspath(path)
    if not isinstance(spelling, str):
        raise AcceptanceError(f"path must be text, got {type(spelling).__name__}")
    if windows is None:
        windows = os.name == "nt"
    if not windows:
        return spelling

    # Foundation renders Windows file URLs with forward slashes, including //?/C:/.
    # Normalize separators before constructing the Win32 extended spelling; the
    # extended namespace itself must only receive backslashes.
    spelling = spelling.replace("/", "\\")
    windows_path = PureWindowsPath(spelling)
    if not windows_path.is_absolute():
        raise AcceptanceError(f"Windows extended path must be absolute: {spelling!r}")
    if "." in spelling.split("\\") or ".." in spelling.split("\\"):
        raise AcceptanceError(f"Windows extended path must not contain dot components: {spelling!r}")

    extended_prefix = "\\\\?\\"
    if spelling.startswith(extended_prefix):
        if spelling[:8].casefold() == "\\\\?\\unc\\":
            unc_parts = windows_path.drive[8:].split("\\")
            if len(unc_parts) < 2 or not all(unc_parts[:2]):
                raise AcceptanceError(f"extended UNC path must include a server and share: {spelling!r}")
        return spelling

    if windows_path.drive.startswith("\\\\"):
        unc_parts = windows_path.drive[2:].split("\\")
        if len(unc_parts) != 2 or not all(unc_parts):
            raise AcceptanceError(f"UNC path must include a server and share: {spelling!r}")
        return "\\\\?\\UNC\\" + spelling[2:]

    if (
        len(spelling) < 3
        or not spelling[0].isascii()
        or not spelling[0].isalpha()
        or spelling[1:3] != ":\\"
    ):
        raise AcceptanceError(f"Windows path must be an absolute drive or UNC path: {spelling!r}")
    return extended_prefix + spelling


def _resolve_path(path: Path, *, strict: bool) -> Path:
    """Resolve a path while keeping the extended Windows spelling intact."""
    normalized = Path(_extended_path_spelling(path))
    resolved = normalized.resolve(strict=strict)
    return Path(_extended_path_spelling(resolved))


def _duplicate_rejecting_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise AcceptanceError(f"duplicate JSON object key: {key!r}")
        result[key] = value
    return result


def _reject_json_constant(value: str) -> None:
    raise AcceptanceError(f"non-standard JSON numeric constant: {value}")


def _finite_json_float(value: str) -> float:
    parsed = float(value)
    if not math.isfinite(parsed):
        raise AcceptanceError(f"non-finite JSON number: {value}")
    return parsed


def strict_json(data: bytes, context: str) -> Any:
    try:
        text = data.decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise AcceptanceError(f"{context}: invalid UTF-8: {error}") from error
    try:
        return json.loads(
            text,
            object_pairs_hook=_duplicate_rejecting_object,
            parse_constant=_reject_json_constant,
            parse_float=_finite_json_float,
        )
    except (json.JSONDecodeError, AcceptanceError) as error:
        raise AcceptanceError(f"{context}: invalid strict JSON: {error}") from error


def canonical_id(value: Any, field: str) -> int:
    if not isinstance(value, str) or not value or value[0] == "0" or not value.isascii() or not value.isdecimal():
        raise AcceptanceError(f"{field} is not a canonical positive decimal string: {value!r}")
    parsed = int(value)
    if parsed <= 0 or parsed > (1 << 64) - 1 or str(parsed) != value:
        raise AcceptanceError(f"{field} is outside the canonical UInt64 range: {value!r}")
    return parsed


def _put_until_stopped(target: queue.Queue[Any], item: Any, stopped: threading.Event) -> bool:
    while not stopped.is_set():
        try:
            target.put(item, timeout=0.1)
            return True
        except queue.Full:
            continue
    return False


class EngineChild:
    """One strictly checked binary-pipe connection to the real harness executable."""

    def __init__(self, executable: Path, root: Path, fixture: Path, rate: int, channels: int):
        self.deadline = time.monotonic() + SCENARIO_TIMEOUT_SECONDS
        argv = [
            str(executable),
            "--root",
            str(root),
            "--fixture",
            str(fixture),
            "--sample-rate",
            str(rate),
            "--channels",
            str(channels),
        ]
        try:
            self.process = subprocess.Popen(
                argv,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=False,
                bufsize=0,
            )
        except OSError as error:
            raise AcceptanceError(f"cannot launch engine harness {executable}: {error}") from error
        if self.process.stdin is None or self.process.stdout is None or self.process.stderr is None:
            self.process.kill()
            self.process.wait(timeout=STDIO_TIMEOUT_SECONDS)
            raise AcceptanceError("engine harness pipes were not created")
        self.stdin = self.process.stdin
        self.stdout = self.process.stdout
        self.stderr = self.process.stderr
        self.records: queue.Queue[Any] = queue.Queue(maxsize=16)
        self.stop_threads = threading.Event()
        self.stderr_lock = threading.Lock()
        self.stderr_tail = bytearray()
        self.thread_errors: list[tuple[str, BaseException]] = []
        self.thread_error_lock = threading.Lock()
        self.stdout_eof = False
        self.input_closed = False
        self.closed = False
        self.ready_seen = False
        self.last_sequence = 0
        self.next_request_id = 1
        self.requests: dict[str, dict[str, Any]] = {}
        self.protocol_failure_expected = False
        self.protocol_failure_count = 0
        self.write_thread: threading.Thread | None = None

        self.stdout_thread = threading.Thread(
            target=self._read_stdout, name="engine-acceptance-stdout", daemon=True
        )
        self.stderr_thread = threading.Thread(
            target=self._drain_stderr, name="engine-acceptance-stderr", daemon=True
        )
        self.stdout_thread.start()
        self.stderr_thread.start()

    def remaining(self, context: str) -> float:
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise AcceptanceError(f"{context}: scenario exceeded its {SCENARIO_TIMEOUT_SECONDS:g}s deadline")
        return remaining

    def _thread_error(self) -> str | None:
        with self.thread_error_lock:
            if not self.thread_errors:
                return None
            name, error = self.thread_errors[0]
        return f"{name} thread failed: {error!r}"

    def _save_thread_error(self, name: str, error: BaseException) -> None:
        with self.thread_error_lock:
            self.thread_errors.append((name, error))

    def _read_stdout(self) -> None:
        line = bytearray()
        try:
            while not self.stop_threads.is_set():
                chunk = self.stdout.read(65_536)
                if not chunk:
                    if line:
                        raise AcceptanceError("stdout ended with a partial NDJSON record (missing LF)")
                    _put_until_stopped(self.records, _EOF, self.stop_threads)
                    return
                for byte in chunk:
                    if byte == 0x0A:
                        if not line:
                            raise AcceptanceError("stdout contained a blank NDJSON record")
                        if len(line) > MAX_RECORD_BYTES:
                            raise AcceptanceError(f"stdout NDJSON record exceeded {MAX_RECORD_BYTES} bytes")
                        if 0x0D in line:
                            raise AcceptanceError("stdout record used CRLF or contained a bare CR; LF is required")
                        if not _put_until_stopped(self.records, bytes(line), self.stop_threads):
                            return
                        line.clear()
                    else:
                        line.append(byte)
                        if len(line) > MAX_RECORD_BYTES:
                            raise AcceptanceError(f"stdout NDJSON record exceeded {MAX_RECORD_BYTES} bytes")
        except BaseException as error:
            self._save_thread_error("stdout reader", error)
            _put_until_stopped(self.records, error, self.stop_threads)

    def _drain_stderr(self) -> None:
        try:
            while not self.stop_threads.is_set():
                chunk = self.stderr.read(8_192)
                if not chunk:
                    return
                with self.stderr_lock:
                    self.stderr_tail.extend(chunk)
                    overflow = len(self.stderr_tail) - MAX_STDERR_BYTES
                    if overflow > 0:
                        del self.stderr_tail[:overflow]
        except BaseException as error:
            self._save_thread_error("stderr drainer", error)

    def diagnostic(self) -> str:
        with self.stderr_lock:
            tail = bytes(self.stderr_tail)
        detail = tail.decode("utf-8", errors="replace").strip()
        thread_error = self._thread_error()
        parts = []
        if detail:
            parts.append(f"stderr tail: {detail}")
        if thread_error:
            parts.append(thread_error)
        return "; ".join(parts) if parts else "stderr was empty"

    def _read_record(self, context: str) -> bytes | object:
        if self.stdout_eof:
            return _EOF
        timeout = min(STDIO_TIMEOUT_SECONDS, self.remaining(context))
        try:
            item = self.records.get(timeout=timeout)
        except queue.Empty as error:
            code = self.process.poll()
            raise AcceptanceError(
                f"{context}: no stdout record within {timeout:g}s (exit={code}); {self.diagnostic()}"
            ) from error
        if isinstance(item, BaseException):
            raise AcceptanceError(f"{context}: stdout reader failed: {item}; {self.diagnostic()}") from item
        thread_error = self._thread_error()
        if thread_error:
            raise AcceptanceError(f"{context}: {thread_error}; {self.diagnostic()}")
        if item is _EOF:
            self.stdout_eof = True
            return _EOF
        if not isinstance(item, bytes):
            raise AcceptanceError(f"{context}: invalid stdout reader item {item!r}")
        return item

    def _validate_envelope(self, line: bytes, context: str) -> tuple[str, str | None, dict[str, Any]]:
        value = strict_json(line, context)
        if not isinstance(value, dict) or set(value) != {"version", "sequence", "request_id", "event", "payload"}:
            raise AcceptanceError(f"{context}: expected exactly the five-key engine envelope, got {value!r}")
        if type(value["version"]) is not int or value["version"] != 1:
            raise AcceptanceError(f"{context}: engine protocol version must be integer 1")
        sequence = canonical_id(value["sequence"], f"{context} sequence")
        if sequence <= self.last_sequence:
            raise AcceptanceError(
                f"{context}: sequence {sequence} is not strictly greater than {self.last_sequence}"
            )
        self.last_sequence = sequence
        request_id = value["request_id"]
        if request_id is not None:
            canonical_id(request_id, f"{context} request_id")
        event = value["event"]
        payload = value["payload"]
        if not isinstance(event, str) or event not in {
            "ready", "state", "accepted", "completed", "progress", "rows", "error"
        }:
            raise AcceptanceError(f"{context}: unknown engine event {event!r}")
        if not isinstance(payload, dict):
            raise AcceptanceError(f"{context}: event payload must be an object")
        return event, request_id, payload

    def _dispatch(self, line: bytes, context: str) -> tuple[str, str | None, dict[str, Any]]:
        event, request_id, payload = self._validate_envelope(line, context)
        if event == "ready":
            if request_id is not None or self.ready_seen:
                raise AcceptanceError(f"{context}: ready must occur exactly once with a null request_id")
            self.ready_seen = True
        elif not self.ready_seen:
            raise AcceptanceError(f"{context}: {event} arrived before ready")

        if event in {"state", "rows"} and request_id is not None:
            raise AcceptanceError(f"{context}: unsolicited {event} must have a null request_id")
        if event == "progress" and request_id is not None and request_id not in self.requests:
            raise AcceptanceError(f"{context}: progress references unknown request_id {request_id}")

        if event == "accepted":
            if request_id is None or set(payload) != {"command"}:
                raise AcceptanceError(f"{context}: accepted requires a known request and command-only payload")
            request = self.requests.get(request_id)
            if request is None:
                raise AcceptanceError(f"{context}: accepted for unknown request_id {request_id}")
            if payload["command"] != request["command"]:
                raise AcceptanceError(f"{context}: accepted command mismatch for request {request_id}")
            request["accepted"] += 1
            if request["accepted"] != 1 or request["terminal"]:
                raise AcceptanceError(f"{context}: duplicate or late accepted event for request {request_id}")
        elif event == "completed":
            if request_id is None or set(payload) != {"command", "result"}:
                raise AcceptanceError(f"{context}: completed requires a known request and command/result payload")
            request = self.requests.get(request_id)
            if request is None:
                raise AcceptanceError(f"{context}: completed for unknown request_id {request_id}")
            if request["accepted"] != 1 or request["terminal"]:
                raise AcceptanceError(f"{context}: completed must follow one accepted event for {request_id}")
            if request["expected_error_code"] is not None:
                raise AcceptanceError(
                    f"{context}: request {request_id} was expected to fail with "
                    f"{request['expected_error_code']!r}, but completed successfully"
                )
            if payload["command"] != request["command"]:
                raise AcceptanceError(f"{context}: completed command mismatch for request {request_id}")
            request["terminal"] += 1
            request["result"] = payload["result"]
        elif event == "error":
            if payload.get("request_id") != request_id:
                raise AcceptanceError(f"{context}: error payload request_id does not match envelope")
            if self.protocol_failure_expected and request_id is None:
                if payload.get("code") != "invalid_request":
                    raise AcceptanceError(
                        f"{context}: expected invalid_request for protocol rejection, got {payload.get('code')!r}"
                    )
                self.protocol_failure_count += 1
                if self.protocol_failure_count != 1:
                    raise AcceptanceError(f"{context}: duplicate protocol rejection")
            elif request_id is not None:
                request = self.requests.get(request_id)
                if request is None:
                    raise AcceptanceError(f"{context}: error for unknown request_id {request_id}")
                expected_code = request["expected_error_code"]
                if expected_code is None:
                    raise AcceptanceError(
                        f"{context}: unexpected engine error code={payload.get('code')!r}, "
                        f"request_id={request_id!r}; {self.diagnostic()}"
                    )
                if request["accepted"] != 1 or request["terminal"]:
                    raise AcceptanceError(f"{context}: expected error must follow one accepted event for {request_id}")
                expected_codes = expected_code if isinstance(expected_code, tuple) else (expected_code,)
                if payload.get("code") not in expected_codes:
                    expected_description = (
                        repr(expected_codes[0])
                        if len(expected_codes) == 1
                        else f"one of {expected_codes!r}"
                    )
                    raise AcceptanceError(
                        f"{context}: request {request_id} expected error code {expected_description}, "
                        f"got {payload.get('code')!r}"
                    )
                request["terminal"] += 1
                request["error"] = payload
            else:
                raise AcceptanceError(
                    f"{context}: unexpected engine error code={payload.get('code')!r}, "
                    f"request_id={request_id!r}; {self.diagnostic()}"
                )
        return event, request_id, payload

    def wait_ready(self) -> dict[str, Any]:
        while True:
            item = self._read_record("waiting for ready")
            if item is _EOF:
                raise AcceptanceError(f"engine exited before ready; {self.diagnostic()}")
            assert isinstance(item, bytes)
            event, _, payload = self._dispatch(item, "ready")
            if event == "ready":
                return payload

    def send_raw(self, data: bytes, *, close_stdin: bool = False, context: str) -> None:
        if self.input_closed:
            raise AcceptanceError(f"{context}: stdin is already closed")
        view = memoryview(data)
        outcome: dict[str, Any] = {"offset": 0, "error": None}
        finished = threading.Event()

        def write_input() -> None:
            try:
                while outcome["offset"] < len(view):
                    offset = outcome["offset"]
                    count = self.stdin.write(view[offset : offset + 65_536])
                    if count is None or count <= 0:
                        raise AcceptanceError(f"stdin accepted no bytes after {offset}")
                    outcome["offset"] += count
                self.stdin.flush()
                if close_stdin:
                    self.close_stdin()
            except BaseException as error:
                outcome["error"] = error
            finally:
                finished.set()

        timeout = min(STDIO_TIMEOUT_SECONDS, self.remaining(context))
        write_deadline = time.monotonic() + timeout
        writer = threading.Thread(target=write_input, name="engine-acceptance-input-writer", daemon=False)
        self.write_thread = writer
        writer.start()
        if not finished.wait(timeout):
            cleanup_error = self._abort_blocked_writer(writer, context)
            suffix = f"; cleanup also failed: {cleanup_error}" if cleanup_error else ""
            raise AcceptanceError(f"{context}: stdin write exceeded {timeout:g}s deadline{suffix}")
        writer.join(timeout=max(0.0, write_deadline - time.monotonic()))

        if writer.is_alive():
            cleanup_error = self._abort_blocked_writer(writer, context)
            suffix = f"; cleanup also failed: {cleanup_error}" if cleanup_error else ""
            raise AcceptanceError(f"{context}: stdin writer thread did not stop{suffix}")
        error = outcome["error"]
        if error is not None:
            if isinstance(error, AcceptanceError):
                raise AcceptanceError(f"{context}: {error}") from error
            if isinstance(error, (BrokenPipeError, OSError)):
                raise AcceptanceError(
                    f"{context}: stdin write failed after {outcome['offset']} bytes: {error}"
                ) from error
            raise AcceptanceError(f"{context}: stdin writer failed: {error!r}") from error
        if close_stdin and not self.input_closed:
            self.close_stdin()

    def _abort_blocked_writer(self, writer: threading.Thread, context: str) -> str | None:
        failures: list[str] = []
        if self.process.poll() is None:
            try:
                self.process.kill()
            except OSError as error:
                if self.process.poll() is None:
                    failures.append(f"could not kill child: {error}")
        try:
            self.process.wait(timeout=STDIO_TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired:
            failures.append(f"killed child was not reaped within {STDIO_TIMEOUT_SECONDS:g}s")
        try:
            self.close_stdin()
        except AcceptanceError as error:
            failures.append(str(error))
        writer.join(timeout=STDIO_TIMEOUT_SECONDS)
        if writer.is_alive():
            failures.append(f"{writer.name} did not stop within {STDIO_TIMEOUT_SECONDS:g}s")
        return "; ".join(failures) if failures else None

    def close_stdin(self) -> None:
        if self.input_closed:
            return
        self.input_closed = True
        try:
            self.stdin.close()
        except OSError as error:
            raise AcceptanceError(f"closing engine stdin failed: {error}") from error

    def call(
        self,
        command: str,
        payload: dict[str, Any],
        *,
        expected_error_code: str | tuple[str, ...] | None = None,
    ) -> Any:
        if not self.ready_seen:
            raise AcceptanceError(f"cannot send {command} before ready")
        request_id = str(self.next_request_id)
        if self.next_request_id > (1 << 64) - 1:
            raise AcceptanceError("engine request id exhausted")
        self.next_request_id += 1
        request = {"version": 1, "request_id": request_id, "command": command, "payload": payload}
        record = json.dumps(request, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode("utf-8") + b"\n"
        self.requests[request_id] = {
            "command": command,
            "accepted": 0,
            "terminal": 0,
            "result": None,
            "error": None,
            "expected_error_code": expected_error_code,
        }
        self.send_raw(record, context=f"sending {command} request {request_id}")
        entry = self.requests[request_id]
        while entry["terminal"] == 0:
            item = self._read_record(f"waiting for {command} request {request_id}")
            if item is _EOF:
                raise AcceptanceError(
                    f"engine exited before {command} request {request_id} completed; {self.diagnostic()}"
                )
            assert isinstance(item, bytes)
            self._dispatch(item, f"response to {command} request {request_id}")
        if entry["accepted"] != 1 or entry["terminal"] != 1:
            raise AcceptanceError(
                f"{command} request {request_id} expected one accepted and one terminal event; "
                f"accepted={entry['accepted']} terminal={entry['terminal']}"
            )
        return entry["error"] if expected_error_code is not None else entry["result"]

    def call_empty(self, command: str) -> Any:
        return self.call(command, {})

    def _drain_to_eof(self, context: str) -> None:
        while not self.stdout_eof:
            item = self._read_record(context)
            if item is _EOF:
                break
            assert isinstance(item, bytes)
            self._dispatch(item, context)

    def verify_request_registry(self) -> None:
        if not self.ready_seen:
            raise AcceptanceError("engine did not emit ready")
        for request_id, request in self.requests.items():
            if request["accepted"] != 1 or request["terminal"] != 1:
                raise AcceptanceError(
                    f"request {request_id} ({request['command']}) did not receive exactly one accepted "
                    f"and one terminal event: accepted={request['accepted']} terminal={request['terminal']}"
                )

    def wait_for_exit(self, expected_code: int | None, context: str) -> int:
        self.close_stdin()
        timeout = min(STDIO_TIMEOUT_SECONDS, self.remaining(context))
        try:
            code = self.process.wait(timeout=timeout)
        except subprocess.TimeoutExpired as error:
            raise AcceptanceError(f"{context}: child did not exit within {timeout:g}s; {self.diagnostic()}") from error
        self._drain_to_eof(f"draining stdout after {context}")
        self._join_threads(context)
        self.verify_request_registry()
        if expected_code is not None and code != expected_code:
            raise AcceptanceError(f"{context}: expected exit code {expected_code}, got {code}; {self.diagnostic()}")
        return code

    def _join_threads(self, context: str) -> None:
        deadline = min(self.deadline, time.monotonic() + STDIO_TIMEOUT_SECONDS)
        for thread in (self.stdout_thread, self.stderr_thread):
            thread.join(timeout=max(0.0, deadline - time.monotonic()))
            if thread.is_alive():
                raise AcceptanceError(f"{context}: {thread.name} did not stop within 30s; {self.diagnostic()}")
        thread_error = self._thread_error()
        if thread_error:
            raise AcceptanceError(f"{context}: {thread_error}; {self.diagnostic()}")

    def kill_and_reap(self, context: str, *, require_nonzero: bool = False) -> int:
        if self.process.poll() is None:
            self.process.kill()
        try:
            code = self.process.wait(timeout=STDIO_TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired as error:
            raise AcceptanceError(f"{context}: killed child was not reaped within 30s") from error
        self.close_stdin()
        self._drain_to_eof(f"draining stdout after {context}")
        self._join_threads(context)
        self.verify_request_registry()
        if require_nonzero and code == 0:
            raise AcceptanceError(f"{context}: forced termination unexpectedly exited with code 0")
        return code

    def close(self) -> None:
        if self.closed:
            return
        failures: list[str] = []
        if self.process.poll() is None:
            try:
                self.process.kill()
            except Exception as error:
                if self.process.poll() is None:
                    failures.append(f"could not kill engine child: {error}")
        try:
            self.process.wait(timeout=STDIO_TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired:
            failures.append(f"engine child was not reaped within {STDIO_TIMEOUT_SECONDS:g}s")
        except Exception as error:
            failures.append(f"waiting for engine child failed: {error}")
        try:
            self.close_stdin()
        except Exception as error:
            failures.append(str(error))
        self.stop_threads.set()
        for thread in (self.stdout_thread, self.stderr_thread, self.write_thread):
            if thread is None:
                continue
            thread.join(timeout=STDIO_TIMEOUT_SECONDS)
            if thread.is_alive() and thread is self.stdout_thread:
                try:
                    self.stdout.close()
                except Exception as error:
                    failures.append(f"closing engine stdout failed: {error}")
                thread.join(timeout=STDIO_TIMEOUT_SECONDS)
            elif thread.is_alive() and thread is self.stderr_thread:
                try:
                    self.stderr.close()
                except Exception as error:
                    failures.append(f"closing engine stderr failed: {error}")
                thread.join(timeout=STDIO_TIMEOUT_SECONDS)
            if thread.is_alive():
                failures.append(f"{thread.name} did not stop within {STDIO_TIMEOUT_SECONDS:g}s")
        for name, stream in (("stdout", self.stdout), ("stderr", self.stderr)):
            try:
                stream.close()
            except Exception as error:
                failures.append(f"closing engine {name} failed: {error}")
        self.closed = True
        if failures:
            raise AcceptanceError("engine child cleanup failed: " + "; ".join(failures))

    def __enter__(self) -> EngineChild:
        return self

    def __exit__(self, exc_type: Any, exc: Any, traceback: Any) -> None:
        try:
            self.close()
        except Exception as cleanup_error:
            if exc is None:
                raise
            raise AcceptanceError(
                f"{type(exc).__name__}: {exc}; cleanup also failed: {cleanup_error}"
            ) from exc


def create_fixture(path: Path, rate: int, channels: int) -> int:
    if path.exists():
        raise AcceptanceError(f"fixture path already exists: {path}")
    if rate not in {16_000, 44_100, 48_000}:
        raise AcceptanceError(f"fixture generator does not support sample rate {rate}")
    if channels == 2:
        channel_offsets = (-0.125, 0.125)
    elif channels == 3:
        channel_offsets = (-0.125, 0.0, 0.125)
    else:
        raise AcceptanceError(f"fixture generator does not support {channels} channels")
    source_frames = rate * 2 + 1_000
    with path.open("xb") as fixture:
        first = 0
        while first < source_frames:
            count = min(1_024, source_frames - first)
            values = [
                (-16_000 + frame * 16_000 / rate) / 32_768 + offset
                for frame in range(first, first + count)
                for offset in channel_offsets
            ]
            packet = struct.pack("<" + "f" * (count * channels), *values)
            fixture.write(packet)
            first += count
    return source_frames


def _required_folder_id(row: dict[str, Any], context: str) -> str:
    if "folder_id" not in row:
        raise AcceptanceError(f"{context}: catalog row is missing folder_id")
    folder_id = row["folder_id"]
    if not isinstance(folder_id, str) or not folder_id:
        raise AcceptanceError(f"{context}: catalog folder_id must be a nonempty string, got {folder_id!r}")
    return folder_id


def _paths_for_session(root: Path, folder_id: str) -> Path:
    sessions_root = root / "mac-ambient-jev" / "sessions"
    if not folder_id or Path(folder_id).name != folder_id or folder_id in {".", ".."}:
        raise AcceptanceError(f"catalog supplied unsafe folder_id {folder_id!r}")
    directory = sessions_root / folder_id
    if not directory.is_dir() or directory.is_symlink():
        raise AcceptanceError(f"catalog folder does not identify a real session directory: {directory}")
    return directory


def _session_rows(result: Any) -> list[dict[str, Any]]:
    if not isinstance(result, dict) or not isinstance(result.get("sessions"), list):
        raise AcceptanceError(f"session.list returned an invalid result: {result!r}")
    if result.get("next_cursor") is not None:
        raise AcceptanceError("acceptance root unexpectedly requires a second catalog page")
    rows = result["sessions"]
    if any(not isinstance(row, dict) for row in rows):
        raise AcceptanceError(f"session.list contained a non-object session: {rows!r}")
    return rows


def _list_sessions(child: EngineChild) -> list[dict[str, Any]]:
    return _session_rows(child.call("session.list", {"cursor": None, "limit": 100}))


def _read_settings(child: EngineChild) -> dict[str, Any]:
    result = child.call_empty("settings.get")
    if not isinstance(result, dict) or not isinstance(result.get("settings"), dict):
        raise AcceptanceError(f"settings.get returned an invalid result: {result!r}")
    settings = result["settings"]
    if settings != EXPECTED_SETTINGS:
        raise AcceptanceError(f"persisted settings mismatch: expected {EXPECTED_SETTINGS!r}, got {settings!r}")
    return settings


def _wait_for_recovery(child: EngineChild) -> dict[str, Any]:
    while True:
        state = child.call_empty("state.get")
        if not isinstance(state, dict):
            raise AcceptanceError(f"state.get returned a non-object: {state!r}")
        recovery = state.get("recovery")
        queue_state = state.get("queue")
        if recovery == "failed":
            raise AcceptanceError(f"startup recovery failed: {state!r}")
        if recovery == "completed" and queue_state == []:
            return state
        child.remaining("waiting for startup recovery")
        time.sleep(min(0.25, child.remaining("waiting for startup recovery")))


def _wait_recording_state(child: EngineChild, session_id: str) -> dict[str, Any]:
    state = child.call_empty("state.get")
    recording = state.get("recording") if isinstance(state, dict) else None
    if not isinstance(recording, dict) or recording.get("session_id") != session_id or recording.get("phase") != "recording":
        raise AcceptanceError(f"recording.start did not leave the expected recording state: {state!r}")
    if state.get("screen") != "live":
        raise AcceptanceError(f"recording screen is not live after start: {state!r}")
    return state


def _wait_finalized(child: EngineChild, session_id: str, timeout: float) -> dict[str, Any]:
    deadline = min(child.deadline, time.monotonic() + timeout)
    while True:
        rows = _list_sessions(child)
        matches = [row for row in rows if row.get("session_id") == session_id]
        if len(matches) > 1:
            raise AcceptanceError(f"catalog contains duplicate rows for session {session_id}")
        if matches:
            row = matches[0]
            status = row.get("status")
            if status == "failed":
                raise AcceptanceError(f"session finalization failed: {row!r}")
            if status == "finalized":
                return row
        if time.monotonic() >= deadline:
            raise AcceptanceError(f"session {session_id} did not finalize within {timeout:g}s; last catalog={rows!r}")
        time.sleep(min(0.25, deadline - time.monotonic()))


def _validate_provenance(session_dir: Path) -> None:
    metadata_path = session_dir / "processing_metadata.json"
    events_path = session_dir / "events.jsonl"
    try:
        metadata = strict_json(metadata_path.read_bytes(), str(metadata_path))
    except OSError as error:
        raise AcceptanceError(f"cannot read processing metadata {metadata_path}: {error}") from error
    if not isinstance(metadata, dict) or metadata.get("schema_version") != 3:
        raise AcceptanceError(f"processing metadata has an unexpected schema: {metadata!r}")
    finalization = metadata.get("finalization_attempt")
    active_runs = metadata.get("active_runs")
    if not isinstance(finalization, dict) or finalization.get("state") != "complete":
        raise AcceptanceError(f"processing metadata does not publish a completed finalization: {finalization!r}")
    if not isinstance(active_runs, dict):
        raise AcceptanceError("processing metadata does not publish active_runs")

    event_provenance: dict[tuple[str, str], str] = {}
    event_completion: set[tuple[str, str]] = set()
    try:
        event_data = events_path.read_bytes()
    except OSError as error:
        raise AcceptanceError(f"cannot read processing event log {events_path}: {error}") from error
    if not event_data or not event_data.endswith(b"\n"):
        raise AcceptanceError("processing event log is empty or has a partial final record")
    for index, raw_line in enumerate(event_data.splitlines()):
        entry = strict_json(raw_line, f"{events_path} line {index + 1}")
        if not isinstance(entry, dict) or entry.get("schema_version") != 3:
            raise AcceptanceError(f"processing event line {index + 1} has an invalid envelope")
        event_type = entry.get("event_type")
        run_id = entry.get("processing_run_id")
        payload = entry.get("payload")
        if event_type == "processing.run.started":
            if not isinstance(run_id, str) or not isinstance(payload, dict):
                raise AcceptanceError(f"processing.run.started line {index + 1} lacks run provenance")
            stage = payload.get("stage")
            provenance = payload.get("provenance")
            if isinstance(stage, str) and isinstance(provenance, dict):
                engine = provenance.get("engine")
                if isinstance(engine, str):
                    event_provenance[(stage, run_id)] = engine
        elif event_type == "processing.run.completed":
            if not isinstance(run_id, str) or not isinstance(payload, dict):
                raise AcceptanceError(f"processing.run.completed line {index + 1} lacks run identity")
            if payload.get("succeeded") is True:
                stage = payload.get("stage")
                if isinstance(stage, str):
                    event_completion.add((stage, run_id))

    for stage, engine in EXPECTED_PROVENANCE.items():
        run_id = active_runs.get(stage)
        if not isinstance(run_id, str) or not run_id:
            raise AcceptanceError(f"published active_runs has no {stage} run: {active_runs!r}")
        if event_provenance.get((stage, run_id)) != engine:
            raise AcceptanceError(
                f"published {stage} run {run_id!r} has no actual {engine!r} processing.run.started provenance"
            )
        if (stage, run_id) not in event_completion:
            raise AcceptanceError(f"published {stage} run {run_id!r} has no successful completion event")


def _verify_sample_values(samples: list[int], source_frames: int, rate: int, context: str) -> None:
    if rate not in {16_000, 44_100, 48_000}:
        raise AcceptanceError(f"{context}: unsupported source sample rate {rate}")
    quotient, remainder = divmod(source_frames * 16_000, rate)
    permitted_counts = {quotient, quotient + (1 if remainder else 0)}
    if rate == 16_000:
        permitted_counts = {source_frames}
    if len(samples) not in permitted_counts:
        raise AcceptanceError(
            f"{context}: canonical sample count {len(samples)} is not in expected floor/ceil set "
            f"{sorted(permitted_counts)}"
        )
    if rate == 16_000:
        for index, sample in enumerate(samples):
            expected = index - 16_000
            if sample != expected:
                raise AcceptanceError(
                    f"{context}: identity PCM sample {index} is {sample}, expected {expected}"
                )
    else:
        if len(samples) <= 512:
            raise AcceptanceError(f"{context}: no interior samples remain after SRC edge exclusion")
        # This analytic continuous-time ramp has zero curvature, so unity-DC-gain linear interpolation/filtering
        # preserves it away from start/EOS transients. SRC group-delay compensation rounds to at most one output
        # frame; Float32 input and signed-16-bit rounding add only small quantization. Eight LSB is conservative
        # and far below a 512-source-frame displacement (~171/186 output LSB at 48/44.1 kHz).
        for index in range(256, len(samples) - 256):
            expected = index - 16_000
            actual = samples[index]
            if abs(actual - expected) > 8:
                raise AcceptanceError(
                    f"{context}: interior SRC sample {index} is {actual}, expected {expected} within 8 integer LSB"
                )


def _validate_flac_file(
    path: Path,
    source_frames: int,
    rate: int,
    context: str,
    *,
    expected_samples: list[int] | None = None,
) -> dict[str, Any]:
    try:
        result = validate_flac(path)
    except (OSError, ValueError) as error:
        raise AcceptanceError(f"{context}: invalid FLAC at {path}: {error}") from error
    if result["sample_rate"] != 16_000 or result["channels"] != 1 or result["bits_per_sample"] != 16:
        raise AcceptanceError(f"{context}: FLAC is not canonical mono 16 kHz/16-bit: {result!r}")
    samples = result.get("samples")
    if not isinstance(samples, list) or any(type(sample) is not int for sample in samples):
        raise AcceptanceError(f"{context}: FLAC decoder did not return signed integer PCM")
    if result["sample_count"] != len(samples):
        raise AcceptanceError(f"{context}: FLAC sample count and decoded PCM length disagree")
    if result["frame_count"] != (len(samples) + 4_095) // 4_096:
        raise AcceptanceError(f"{context}: FLAC frame count does not match decoded PCM length")
    if expected_samples is None:
        _verify_sample_values(samples, source_frames, rate, context)
    elif samples != expected_samples:
        mismatch = None
        for index, expected in enumerate(expected_samples):
            actual = samples[index] if index < len(samples) else None
            if actual != expected:
                mismatch = (index, expected, actual)
                break
        if mismatch is None and len(samples) > len(expected_samples):
            mismatch = (len(expected_samples), None, samples[len(expected_samples)])
        raise AcceptanceError(
            f"{context}: PCM differs from the committed prefix; expected_frames={len(expected_samples)} "
            f"actual_frames={len(samples)} first_mismatch={mismatch!r}"
        )
    return result


def _assert_reparse_destination_rejected(
    child: EngineChild,
    session_dir: Path,
    session_id: str,
    owner: Path,
    export_parent: Path,
    target_directory: Path,
    existing_bundle: Path,
    original_bundle: dict[str, bytes],
) -> None:
    _check_owned_path(owner, export_parent)
    _check_owned_path(owner, target_directory)
    export_parent.mkdir(parents=False, exist_ok=False)
    target_directory.mkdir(parents=False, exist_ok=False)
    for directory in (export_parent, target_directory):
        if directory.is_symlink() or not directory.is_dir() or _resolve_path(directory, strict=True) != directory:
            raise AcceptanceError(f"child reparse-point export directory is not the exact real directory created: {directory}")
    if any(target_directory.iterdir()):
        raise AcceptanceError(f"reparse-point export target was not empty: {target_directory}")
    destination_link = export_parent / session_dir.name
    if existing_bundle.name != session_dir.name:
        raise AcceptanceError("good export bundle name does not match the session directory")
    _check_owned_path(owner, destination_link)
    try:
        os.symlink(target_directory, destination_link, target_is_directory=True)
    except OSError as error:
        platform_hint = "; on Windows, enable Developer Mode or run with symlink privileges" if os.name == "nt" else ""
        raise AcceptanceError(
            f"required child directory symlink/reparse-point creation failed for {destination_link}: "
            f"{error}{platform_hint}"
        ) from error
    if not destination_link.is_symlink():
        raise AcceptanceError(f"created child export link is not a symlink/reparse point: {destination_link}")
    _check_owned_path(owner, destination_link)
    if _resolve_path(destination_link, strict=True) != _resolve_path(target_directory, strict=True):
        raise AcceptanceError(f"child export symlink does not resolve to its owned target: {destination_link}")

    request_id = str(child.next_request_id)
    error_result = child.call(
        "session.export",
        {"session_id": session_id, "destination_path": str(export_parent)},
        expected_error_code=("export_failure", "filesystem"),
    )
    request = child.requests[request_id]
    if request["accepted"] != 1 or request["terminal"] != 1:
        raise AcceptanceError(
            "child reparse-point export must receive exactly one accepted and one terminal event: "
            f"accepted={request['accepted']} terminal={request['terminal']}"
        )
    if not isinstance(error_result, dict) or error_result.get("code") not in {"export_failure", "filesystem"}:
        raise AcceptanceError(f"child reparse-point export returned an unexpected error: {error_result!r}")
    if not destination_link.is_symlink():
        raise AcceptanceError(f"rejected child reparse-point export changed its symlink: {destination_link}")
    if _resolve_path(destination_link, strict=True) != _resolve_path(target_directory, strict=True):
        raise AcceptanceError(f"rejected child reparse-point export retargeted its symlink: {destination_link}")
    target_entries = sorted(path.relative_to(target_directory).as_posix() for path in target_directory.rglob("*"))
    if target_entries:
        raise AcceptanceError(f"rejected child reparse-point export wrote into its target: {target_entries!r}")
    current_names = sorted(path.name for path in existing_bundle.iterdir())
    bundle_now = {path.name: path.read_bytes() for path in existing_bundle.iterdir() if path.is_file()}
    if current_names != sorted(original_bundle) or bundle_now != original_bundle:
        raise AcceptanceError("rejected child reparse-point export changed the previously good bundle")
    print(f"scenario=child-reparse-export-rejected error_code={error_result['code']} target_empty=true symlink_preserved=true")
    # The TemporaryDirectory owner removes this symlink itself; its target remains inside that owner.


def _validate_export_and_audio(
    child: EngineChild,
    session_dir: Path,
    session_id: str,
    source_frames: int,
    rate: int,
    export_destination: Path,
    *,
    expected_pcm_prefix: list[int] | None = None,
    reparse_export: tuple[Path, Path, Path] | None = None,
) -> dict[str, Any]:
    transcript_result = child.call(
        "transcript.read",
        {"session_id": session_id, "revision": None, "cursor": None, "limit": 200},
    )
    if not isinstance(transcript_result, dict) or transcript_result.get("session_id") != session_id:
        raise AcceptanceError(f"transcript.read returned the wrong session: {transcript_result!r}")
    rows = transcript_result.get("rows")
    if not isinstance(rows, list) or len(rows) != 1:
        raise AcceptanceError(f"expected exactly one final transcript row, got {rows!r}")
    row = rows[0]
    if not isinstance(row, dict) or row.get("text") != TRANSCRIPT_TEXT or row.get("headings") != ["Speaker 1"]:
        raise AcceptanceError(f"final transcript content or speaker heading mismatch: {row!r}")
    if transcript_result.get("next_cursor") is not None:
        raise AcceptanceError("one-row transcript unexpectedly has another page")

    _validate_provenance(session_dir)
    audio_dir = session_dir / "audio"
    retained_flac = audio_dir / "recording.flac"
    retained = _validate_flac_file(
        retained_flac,
        source_frames,
        rate,
        "retained recording",
        expected_samples=expected_pcm_prefix,
    )

    for export_number in (1, 2):
        export_result = child.call(
            "session.export",
            {"session_id": session_id, "destination_path": str(export_destination)},
        )
        if not isinstance(export_result, dict) or export_result.get("session_id") != session_id:
            raise AcceptanceError(f"session.export #{export_number} returned an invalid result: {export_result!r}")
        if not isinstance(export_result.get("destination_path"), str):
            raise AcceptanceError(f"session.export #{export_number} omitted destination_path")
        bundle_path = Path(_extended_path_spelling(export_result["destination_path"]))
        try:
            bundle = _resolve_path(bundle_path, strict=True)
            expected_bundle = _resolve_path(export_destination / session_dir.name, strict=True)
        except OSError as error:
            raise AcceptanceError(f"session.export #{export_number} destination is missing: {error}") from error
        if bundle != expected_bundle:
            raise AcceptanceError(
                f"session.export #{export_number} wrote to {bundle}, expected {expected_bundle}"
            )
        names = sorted(path.name for path in bundle.iterdir())
        if names != ["audio.flac", "transcript.txt"]:
            raise AcceptanceError(f"export bundle must contain exactly audio.flac and transcript.txt, got {names!r}")
        exported_text = (bundle / "transcript.txt").read_bytes()
        if exported_text != TRANSCRIPT_FILE.encode("utf-8"):
            raise AcceptanceError(f"exported transcript.txt bytes mismatch: {exported_text!r}")
        exported_audio_path = bundle / "audio.flac"
        exported = _validate_flac_file(
            exported_audio_path,
            source_frames,
            rate,
            f"exported FLAC #{export_number}",
            expected_samples=expected_pcm_prefix,
        )
        retained_bytes = retained_flac.read_bytes()
        exported_bytes = exported_audio_path.read_bytes()
        if retained_bytes != exported_bytes:
            raise AcceptanceError("exported audio.flac is not byte-for-byte identical to retained recording.flac")
        if export_number == 1:
            first_export = {name: (bundle / name).read_bytes() for name in names}
        elif {name: (bundle / name).read_bytes() for name in names} != first_export:
            raise AcceptanceError("replacing the explicit Unicode export destination changed output bytes")
        if exported["md5"] != retained["md5"] or exported["sample_count"] != retained["sample_count"]:
            raise AcceptanceError("retained and exported FLAC decoder summaries disagree")

    if reparse_export is not None:
        owner, export_parent, target_directory = reparse_export
        _assert_reparse_destination_rejected(
            child,
            session_dir,
            session_id,
            owner,
            export_parent,
            target_directory,
            bundle,
            first_export,
        )
    return retained


def _validate_checkpoint(session_dir: Path, full_frames: int) -> tuple[int, list[bytes], list[int]]:
    processing = session_dir / "audio" / "processing"
    checkpoint_path = processing / "checkpoint.json"
    try:
        checkpoint = strict_json(checkpoint_path.read_bytes(), str(checkpoint_path))
    except OSError as error:
        raise AcceptanceError(f"cannot read committed capture checkpoint {checkpoint_path}: {error}") from error
    expected_keys = {
        "committedFrames", "sampleRate", "channelCount", "sampleFormat", "chunkFiles", "chunkFrameCounts", "gapEvents"
    }
    if not isinstance(checkpoint, dict) or set(checkpoint) != expected_keys:
        raise AcceptanceError(
            f"checkpoint.json does not match AudioCheckpoint's synthesized Codable field names: {checkpoint!r}"
        )
    committed = checkpoint["committedFrames"]
    files = checkpoint["chunkFiles"]
    counts = checkpoint["chunkFrameCounts"]
    if type(committed) is not int or not 0 < committed < full_frames:
        raise AcceptanceError(
            f"checkpoint committedFrames must be positive and less than the {full_frames}-frame fixture; got {committed!r}"
        )
    if checkpoint["sampleRate"] != 16_000 or checkpoint["channelCount"] != 1:
        raise AcceptanceError(f"checkpoint is not canonical mono PCM: {checkpoint!r}")
    if not isinstance(files, list) or not isinstance(counts, list) or len(files) != len(counts) or not files:
        raise AcceptanceError(f"checkpoint chunk files/counts are invalid: {checkpoint!r}")
    if any(type(count) is not int or count <= 0 for count in counts):
        raise AcceptanceError(f"checkpoint chunk frame counts must be positive integers: {checkpoint!r}")
    if sum(counts) != committed:
        raise AcceptanceError(f"checkpoint chunk counts do not total committedFrames: {checkpoint!r}")

    chunk_bytes: list[bytes] = []
    expected_pcm: list[int] = []
    for filename, frame_count in zip(files, counts, strict=True):
        if not isinstance(filename, str) or Path(filename).name != filename or filename in {".", ".."}:
            raise AcceptanceError(f"checkpoint contains an unsafe chunk filename: {filename!r}")
        path = processing / filename
        try:
            data = path.read_bytes()
        except OSError as error:
            raise AcceptanceError(f"cannot read committed chunk {path}: {error}") from error
        if len(data) != frame_count * 4:
            raise AcceptanceError(f"committed chunk {filename} byte length does not match {frame_count} frames")
        values = struct.unpack("<" + "f" * frame_count, data)
        quantized: list[int] = []
        for value in values:
            if not (value == value and abs(value) != float("inf")):
                raise AcceptanceError(f"committed chunk {filename} contains non-finite PCM")
            sample = round(value * 32_768)
            if not -32_768 <= sample <= 32_767:
                raise AcceptanceError(f"committed chunk {filename} quantizes outside signed 16-bit PCM")
            quantized.append(sample)
        first_frame = len(expected_pcm)
        for offset, sample in enumerate(quantized):
            global_frame = first_frame + offset
            expected = global_frame - 16_000
            if sample != expected:
                raise AcceptanceError(
                    f"committed chunk {filename} sample {offset} (global frame {global_frame}) is {sample}, "
                    f"expected {expected}"
                )
        expected_pcm.extend(quantized)
        chunk_bytes.append(data)
    if len(expected_pcm) != committed:
        raise AcceptanceError("checkpoint PCM prefix length does not match committedFrames")
    return committed, chunk_bytes, expected_pcm


def _start_recording(child: EngineChild) -> str:
    result = child.call(
        "recording.start",
        {"source": "microphone", "device": {"kind": "default"}},
    )
    if not isinstance(result, dict) or not isinstance(result.get("session_id"), str) or not result["session_id"]:
        raise AcceptanceError(f"recording.start returned an invalid session_id: {result!r}")
    session_id = result["session_id"]
    _wait_recording_state(child, session_id)
    return session_id


def _setup_new_session(child: EngineChild) -> None:
    child.wait_ready()
    hello = child.call_empty("hello")
    if not isinstance(hello, dict) or not isinstance(hello.get("state"), dict):
        raise AcceptanceError(f"hello returned an invalid ready state: {hello!r}")
    result = child.call("settings.replace", {"expected_revision": None, "settings": EXPECTED_SETTINGS})
    if not isinstance(result, dict) or result.get("settings") != EXPECTED_SETTINGS:
        raise AcceptanceError(f"settings.replace did not persist all ten required settings: {result!r}")
    child.call_empty("models.prepare")
    _wait_for_recovery(child)


def run_audio_scenario(
    executable: Path,
    root: Path,
    fixture: Path,
    rate: int,
    channels: int,
    source_frames: int,
    label: str,
    export_destination: Path,
    reparse_export: tuple[Path, Path, Path] | None = None,
) -> dict[str, Any]:
    with EngineChild(executable, root, fixture, rate, channels) as child:
        _setup_new_session(child)
        session_id = _start_recording(child)
        recording_rows = _list_sessions(child)
        active = [row for row in recording_rows if row.get("session_id") == session_id]
        if len(active) != 1 or active[0].get("status") != "recording":
            raise AcceptanceError(f"recording catalog entry was not unique and recording: {recording_rows!r}")
        _paths_for_session(root, _required_folder_id(active[0], "recording catalog row"))
        stop = child.call("recording.stop", {"session_id": session_id})
        if not isinstance(stop, dict) or stop.get("session_id") != session_id:
            raise AcceptanceError(f"recording.stop returned the wrong session: {stop!r}")
        finalized = _wait_finalized(child, session_id, FINALIZATION_TIMEOUT_SECONDS)
        session_dir = _paths_for_session(root, _required_folder_id(finalized, "finalized catalog row"))
        state = child.call_empty("state.get")
        if not isinstance(state, dict) or state.get("queue") != []:
            raise AcceptanceError(f"processing queue was not empty after finalization: {state!r}")
        retained = _validate_export_and_audio(
            child,
            session_dir,
            session_id,
            source_frames,
            rate,
            export_destination,
            reparse_export=reparse_export,
        )
        child.call_empty("shutdown")
        child.wait_for_exit(0, f"{label} shutdown")
    print(
        f"scenario={label} source_frames={source_frames} canonical_samples={retained['sample_count']} "
        f"flac_frames={retained['frame_count']} pcm_md5={retained['md5']}"
    )
    return retained


def run_forced_kill_recovery(
    executable: Path,
    root: Path,
    fixture: Path,
    source_frames: int,
    export_destination: Path,
) -> None:
    with EngineChild(executable, root, fixture, 16_000, 2) as child:
        _setup_new_session(child)
        session_id = _start_recording(child)
        rows = _list_sessions(child)
        matches = [row for row in rows if row.get("session_id") == session_id]
        if len(matches) != 1 or matches[0].get("status") != "recording":
            raise AcceptanceError(f"pre-kill catalog does not contain one recording session: {rows!r}")
        folder_id = _required_folder_id(matches[0], "pre-kill catalog row")
        session_dir = _paths_for_session(root, folder_id)
        committed, committed_chunk_bytes, expected_pcm = _validate_checkpoint(session_dir, source_frames)
        # Keep the exact durable chunk snapshots alive across the forced process termination.
        expected_chunk_sizes = [len(chunk) for chunk in committed_chunk_bytes]
        code = child.kill_and_reap("forced recording-process kill", require_nonzero=True)
        print(
            f"scenario=forced-kill checkpoint_committed_frames={committed} full_fixture_frames={source_frames} "
            f"committed_chunks={len(committed_chunk_bytes)} chunk_bytes={expected_chunk_sizes} kill_exit={code}"
        )

    with EngineChild(executable, root, fixture, 16_000, 2) as child:
        child.wait_ready()
        hello = child.call_empty("hello")
        if not isinstance(hello, dict) or not isinstance(hello.get("state"), dict):
            raise AcceptanceError(f"recovery hello returned an invalid state: {hello!r}")
        _read_settings(child)
        child.call_empty("models.prepare")
        _wait_for_recovery(child)
        finalized = _wait_finalized(child, session_id, FINALIZATION_TIMEOUT_SECONDS)
        catalog = _list_sessions(child)
        if len(catalog) != 1 or catalog[0].get("session_id") != session_id:
            raise AcceptanceError(f"recovery must preserve exactly the original session, got {catalog!r}")
        if finalized.get("session_id") != session_id:
            raise AcceptanceError(f"recovery finalized a different session: {finalized!r}")
        session_dir = _paths_for_session(root, _required_folder_id(finalized, "finalized catalog row"))
        if session_dir.name != folder_id:
            raise AcceptanceError(f"recovery changed session folder_id from {folder_id!r} to {session_dir.name!r}")
        retained = _validate_export_and_audio(
            child,
            session_dir,
            session_id,
            source_frames,
            16_000,
            export_destination,
            expected_pcm_prefix=expected_pcm,
        )
        if retained["sample_count"] != committed:
            raise AcceptanceError(
                f"recovered FLAC contains {retained['sample_count']} samples; checkpoint committed {committed}; "
                "recovery must not invent the uncommitted tail"
            )
        child.call_empty("shutdown")
        child.wait_for_exit(0, "recovered-session shutdown")
    print(
        f"scenario=forced-kill-recovered session_id={session_id} committed_frames={committed} "
        f"full_fixture_frames={source_frames} canonical_samples={retained['sample_count']} "
        f"flac_frames={retained['frame_count']} pcm_md5={retained['md5']}"
    )


def _session_tree_has_mutations(sessions_root: Path) -> bool:
    if not sessions_root.exists():
        return False
    if not sessions_root.is_dir() or sessions_root.is_symlink():
        raise AcceptanceError(f"sessions root is not a real directory: {sessions_root}")
    return any(sessions_root.iterdir())


def run_protocol_rejection(
    executable: Path,
    root: Path,
    fixture: Path,
    *,
    oversized: bool,
) -> None:
    sessions_root = root / "mac-ambient-jev" / "sessions"
    if _session_tree_has_mutations(sessions_root):
        raise AcceptanceError(f"protocol rejection test root already has session data: {sessions_root}")
    with EngineChild(executable, root, fixture, 16_000, 2) as child:
        child.wait_ready()
        child.protocol_failure_expected = True
        if oversized:
            # Send a well-formed-looking request prefix and enough bytes to cross the one-MiB record cap.
            data = b'{"version":1,"request_id":"1","command":"hello","payload":{}}' + b" " * (MAX_RECORD_BYTES + 2)
            write_errors: list[BaseException] = []
            sent = 0

            def oversized_writer() -> None:
                nonlocal sent
                view = memoryview(data)
                try:
                    while sent < len(view):
                        count = child.stdin.write(view[sent : sent + 65_536])
                        if count is None or count <= 0:
                            raise AcceptanceError(f"oversized stdin write accepted no bytes after {sent}")
                        sent += count
                except BaseException as error:
                    write_errors.append(error)

            writer = threading.Thread(target=oversized_writer, name="engine-acceptance-oversized-writer", daemon=True)
            writer.start()
            timeout = min(STDIO_TIMEOUT_SECONDS, child.remaining("oversized request termination"))
            try:
                code = child.process.wait(timeout=timeout)
            except subprocess.TimeoutExpired as error:
                raise AcceptanceError(f"oversized request did not terminate within {timeout:g}s") from error
            writer.join(timeout=STDIO_TIMEOUT_SECONDS)
            if writer.is_alive():
                raise AcceptanceError("oversized request writer did not stop within 30s")
            if sent < MAX_RECORD_BYTES + 1:
                raise AcceptanceError(f"oversized writer sent only {sent} bytes before the child exited")
            if write_errors and (
                code != 3 or not isinstance(write_errors[0], (BrokenPipeError, OSError))
            ):
                raise AcceptanceError(f"oversized stdin writer failed unexpectedly: {write_errors[0]!r}")
            if code != 3:
                raise AcceptanceError(f"oversized input must exit 3, got {code}; {child.diagnostic()}")
            child.close_stdin()
            child._drain_to_eof("draining oversized protocol response")
            child._join_threads("oversized protocol response")
            child.verify_request_registry()
            if child.protocol_failure_count != 1:
                raise AcceptanceError(
                    f"oversized input expected exactly one null-ID invalid_request, got {child.protocol_failure_count}"
                )
            print(f"scenario=oversized-stdin bytes_sent={sent} exit={code} protocol_errors={child.protocol_failure_count}")
        else:
            partial = b'{"version":1,"request_id":"1","command":"hello","payload":{}'
            child.send_raw(partial, close_stdin=True, context="sending partial final line")
            code = child.wait_for_exit(3, "partial-final-line protocol rejection")
            if code != 3:
                raise AcceptanceError(f"partial final line must exit 3, got {code}")
            if child.protocol_failure_count != 1:
                raise AcceptanceError(
                    f"partial EOF expected exactly one null-ID invalid_request, got {child.protocol_failure_count}"
                )
            print(f"scenario=partial-final-line bytes_sent={len(partial)} exit={code} protocol_errors={child.protocol_failure_count}")
    if _session_tree_has_mutations(sessions_root):
        raise AcceptanceError("invalid stdin mutated session storage or created a session")


def _make_root(owner: Path, name: str, *, long_path: bool = False) -> Path:
    if long_path:
        components = ["p4-windows-long-root"]
        index = 0
        while len(str(owner.joinpath(*components))) <= 275:
            components.append(f"long-component-{index:02d}-" + "x" * 43)
            index += 1
        if any(len(component) >= 80 for component in components):
            raise AcceptanceError("long-path root component unexpectedly reached 80 characters")
        root = owner.joinpath(*components, name)
    else:
        root = owner / name
    root = _resolve_path(root, strict=False)
    root.mkdir(parents=True, exist_ok=False)
    resolved = _resolve_path(root, strict=True)
    if resolved != root or root.is_symlink() or not root.is_dir():
        raise AcceptanceError(f"scenario root is not the exact real directory created: {root}")
    if long_path and len(str(root)) <= 260:
        raise AcceptanceError(f"Windows long-path scenario root is only {len(str(root))} characters")
    return root


def _check_owned_path(owner: Path, path: Path) -> None:
    resolved_owner = _resolve_path(owner, strict=True)
    resolved = _resolve_path(path, strict=False)
    try:
        resolved.relative_to(resolved_owner)
    except ValueError as error:
        raise AcceptanceError(f"refusing to use path outside owned temporary directory: {path}") from error


def _resolve_executable(argv: list[str]) -> Path:
    if len(argv) != 2 or argv[0] != "--executable":
        raise AcceptanceError("usage: python3 -B scripts/engine_acceptance.py --executable PATH")
    candidate = Path(argv[1])
    if not candidate.exists() or not candidate.is_file():
        raise AcceptanceError(f"--executable must identify an existing file: {candidate}")
    executable = candidate.resolve(strict=True)
    if not executable.is_file():
        raise AcceptanceError(f"resolved --executable is not a regular file: {executable}")
    if os.name != "nt" and not os.access(executable, os.X_OK):
        raise AcceptanceError(f"--executable is not executable: {executable}")
    return executable


def run(executable: Path) -> None:
    if sys.platform == "darwin":
        profile = "macOS-full"
        formats = [(44_100, 3, "44100Hz-3ch", False), (48_000, 2, "48000Hz-2ch", False)]
    elif sys.platform == "win32":
        profile = "Windows-full-with-explicit-long-path"
        formats = [(44_100, 3, "44100Hz-3ch-longpath", True), (48_000, 2, "48000Hz-2ch", False)]
    elif sys.platform.startswith("linux"):
        profile = "Linux-canonical-only; noncanonical resampling scenarios are not attempted"
        formats = []
    else:
        raise AcceptanceError(f"unsupported acceptance-driver platform: {sys.platform}")
    print(f"profile={profile}")

    temporary_parent: str | None = None
    if os.name == "nt":
        existing_temp_parent = _resolve_path(Path(tempfile.gettempdir()), strict=True)
        temporary_parent = str(existing_temp_parent)
    with tempfile.TemporaryDirectory(
        prefix="engine acceptance 日本語 ",
        dir=temporary_parent,
    ) as temporary:
        temporary_path = Path(_extended_path_spelling(temporary))
        if os.name == "nt" and not str(temporary_path).startswith("\\\\?\\"):
            raise AcceptanceError(f"TemporaryDirectory did not preserve the extended temp parent spelling: {temporary}")
        owner = _resolve_path(temporary_path, strict=True)
        if os.name == "nt" and owner != temporary_path:
            raise AcceptanceError(f"temporary workspace resolved to a different path spelling: {owner}")
        if not owner.is_dir() or owner.is_symlink():
            raise AcceptanceError(f"temporary workspace is not a real owned directory: {owner}")

        fixtures = owner / "fixtures"
        fixtures.mkdir()
        canonical_fixture = fixtures / "canonical stereo.f32le"
        canonical_frames = create_fixture(canonical_fixture, 16_000, 2)
        _check_owned_path(owner, canonical_fixture)
        reparse_export_parent = owner / "exports canonical 日本語 child reparse"
        reparse_target = owner / "child reparse export target"
        _check_owned_path(owner, reparse_export_parent)
        _check_owned_path(owner, reparse_target)
        run_audio_scenario(
            executable,
            _make_root(owner, "canonical root 日本語"),
            canonical_fixture,
            16_000,
            2,
            canonical_frames,
            "canonical16000-stereo",
            owner / "exports canonical 日本語 with spaces",
            reparse_export=(owner, reparse_export_parent, reparse_target),
        )

        for rate, channels, label, long_path in formats:
            fixture = fixtures / f"fixture-{rate}-{channels}ch.f32le"
            source_frames = create_fixture(fixture, rate, channels)
            _check_owned_path(owner, fixture)
            root = _make_root(owner, f"root-{label}", long_path=long_path)
            if long_path:
                print(f"longpath_test=root_length_{len(str(root))}_component_max_{max(map(len, root.parts))}")
            run_audio_scenario(
                executable,
                root,
                fixture,
                rate,
                channels,
                source_frames,
                label,
                root / "exports_日本語 with spaces",
            )

        recovery_root = _make_root(owner, "forced-kill recovery root 日本語")
        run_forced_kill_recovery(
            executable,
            recovery_root,
            canonical_fixture,
            canonical_frames,
            recovery_root / "exports_日本語 with spaces",
        )

        oversized_root = _make_root(owner, "oversized request root")
        run_protocol_rejection(executable, oversized_root, canonical_fixture, oversized=True)
        partial_root = _make_root(owner, "partial final line root")
        run_protocol_rejection(executable, partial_root, canonical_fixture, oversized=False)

        # TemporaryDirectory owns this exact, uniquely allocated tree; all paths above were checked inside it.
        if _resolve_path(temporary_path, strict=True) != owner:
            raise AcceptanceError("temporary workspace owner changed before cleanup")
    print("acceptance=passed")


def main() -> int:
    try:
        executable = _resolve_executable(sys.argv[1:])
        run(executable)
    except AcceptanceError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    except Exception as error:
        print(f"ERROR: unexpected {type(error).__name__}: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
