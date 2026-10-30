#!/usr/bin/env python3
"""Black-box acceptance driver for MacAmbientJevEngineHarness."""

from __future__ import annotations

import argparse
import copy
import importlib.util
import json
import math
import os
import queue
import re
import struct
import subprocess
import sys
import tempfile
import threading
import time
import wave
from pathlib import Path, PureWindowsPath
from typing import Any

from engine_acceptance_flac import validate_flac


MAX_RECORD_BYTES = 1_048_576
MAX_STDERR_BYTES = 65_536
STDIO_TIMEOUT_SECONDS = 30.0
SCENARIO_TIMEOUT_SECONDS = 240.0
FINALIZATION_TIMEOUT_SECONDS = 180.0
FULL_MODEL_SCENARIO_TIMEOUT_SECONDS = 1_200.0
FULL_MODEL_STDIO_TIMEOUT_SECONDS = 300.0
FULL_MODEL_FINALIZATION_TIMEOUT_SECONDS = 600.0
TRANSCRIPT_TEXT = "エンジンの受け入れテストです。"
TRANSCRIPT_FILE = "[00:00] Speaker 1: エンジンの受け入れテストです。\n"
EXPECTED_SETTINGS: dict[str, Any] = {
    "schema_version": 2,
    "source": "microphone",
    "device": {"kind": "default"},
    "asr_size": "0.6b",
    "execution_provider": {"kind": "cpu"},
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


def _process_recording_path(path: str | os.PathLike[str], *, windows: bool) -> str:
    """Format a canonical path for ProcessRecording's ordinary Windows root policy."""
    if not windows:
        return str(path)

    spelling = os.fspath(path)
    if not isinstance(spelling, str):
        raise AcceptanceError(f"path must be text, got {type(spelling).__name__}")
    backslash = "\\"
    normalized = spelling.replace("/", backslash)
    extended_prefix = backslash * 2 + "?" + backslash
    unc_namespace_prefix = "UNC" + backslash
    if normalized.startswith(backslash * 2 + "." + backslash):
        raise AcceptanceError(f"unsupported Windows path namespace: {spelling!r}")
    if normalized.startswith(extended_prefix):
        namespace_path = normalized[len(extended_prefix):]
        if not namespace_path.casefold().startswith(unc_namespace_prefix.casefold()) and re.match(
            r"^[A-Za-z]:" + re.escape(backslash), namespace_path
        ) is None:
            raise AcceptanceError(f"unsupported Windows path namespace: {spelling!r}")

    extended = _extended_path_spelling(path, windows=True)
    unc_prefix = extended_prefix + unc_namespace_prefix
    if extended[:len(unc_prefix)].casefold() == unc_prefix.casefold():
        return backslash * 2 + extended[len(unc_prefix):]
    if extended.startswith(extended_prefix):
        drive_path = extended[len(extended_prefix):]
        if re.match(r"^[A-Za-z]:" + re.escape(backslash), drive_path) is not None:
            return drive_path
    raise AcceptanceError(f"unsupported Windows path namespace: {spelling!r}")


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

    def __init__(
        self,
        executable: Path,
        root: Path,
        fixture: Path,
        rate: int,
        channels: int,
        *,
        inference: str,
        threads: int,
        scenario_timeout: float,
        stdio_timeout: float,
    ):
        if inference not in {"deterministic", "portable"}:
            raise AcceptanceError(f"unsupported inference mode: {inference!r}")
        if type(threads) is not int or threads <= 0:
            raise AcceptanceError(f"threads must be a positive integer, got {threads!r}")
        if scenario_timeout <= 0 or stdio_timeout <= 0:
            raise AcceptanceError("scenario and stdio timeouts must be positive")
        self.inference = inference
        self.threads = threads
        self.scenario_timeout = scenario_timeout
        self.stdio_timeout = stdio_timeout
        self.deadline = time.monotonic() + scenario_timeout
        argv = [
            str(executable),
            "--inference",
            inference,
            "--threads",
            str(threads),
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
            self.process.wait(timeout=self.stdio_timeout)
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
            raise AcceptanceError(f"{context}: scenario exceeded its {self.scenario_timeout:g}s deadline")
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
        timeout = min(self.stdio_timeout, self.remaining(context))
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

        timeout = min(self.stdio_timeout, self.remaining(context))
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
            self.process.wait(timeout=self.stdio_timeout)
        except subprocess.TimeoutExpired:
            failures.append(f"killed child was not reaped within {self.stdio_timeout:g}s")
        try:
            self.close_stdin()
        except AcceptanceError as error:
            failures.append(str(error))
        writer.join(timeout=self.stdio_timeout)
        if writer.is_alive():
            failures.append(f"{writer.name} did not stop within {self.stdio_timeout:g}s")
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
        timeout = min(self.stdio_timeout, self.remaining(context))
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
        deadline = min(self.deadline, time.monotonic() + self.stdio_timeout)
        for thread in (self.stdout_thread, self.stderr_thread):
            thread.join(timeout=max(0.0, deadline - time.monotonic()))
            if thread.is_alive():
                raise AcceptanceError(
                    f"{context}: {thread.name} did not stop within {self.stdio_timeout:g}s; {self.diagnostic()}"
                )
        thread_error = self._thread_error()
        if thread_error:
            raise AcceptanceError(f"{context}: {thread_error}; {self.diagnostic()}")

    def kill_and_reap(self, context: str, *, require_nonzero: bool = False) -> int:
        if self.process.poll() is None:
            self.process.kill()
        try:
            code = self.process.wait(timeout=self.stdio_timeout)
        except subprocess.TimeoutExpired as error:
            raise AcceptanceError(
                f"{context}: killed child was not reaped within {self.stdio_timeout:g}s"
            ) from error
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
            self.process.wait(timeout=self.stdio_timeout)
        except subprocess.TimeoutExpired:
            failures.append(f"engine child was not reaped within {self.stdio_timeout:g}s")
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
            thread.join(timeout=self.stdio_timeout)
            if thread.is_alive() and thread is self.stdout_thread:
                try:
                    self.stdout.close()
                except Exception as error:
                    failures.append(f"closing engine stdout failed: {error}")
                thread.join(timeout=self.stdio_timeout)
            elif thread.is_alive() and thread is self.stderr_thread:
                try:
                    self.stderr.close()
                except Exception as error:
                    failures.append(f"closing engine stderr failed: {error}")
                thread.join(timeout=self.stdio_timeout)
            if thread.is_alive():
                failures.append(f"{thread.name} did not stop within {self.stdio_timeout:g}s")
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


def _acknowledge_resources(child: EngineChild, workload: str) -> None:
    assessment = child.call("resources.preflight", {"workload": workload})
    if not isinstance(assessment, dict) or set(assessment) != {"assessment_id", "result", "reason", "explanation"}:
        raise AcceptanceError(f"{workload} resource preflight returned an invalid assessment: {assessment!r}")
    if (assessment["result"] != "warning" or assessment["reason"] != "envelope_unmeasured"
            or not isinstance(assessment["assessment_id"], str) or not assessment["assessment_id"]
            or not isinstance(assessment["explanation"], str) or not assessment["explanation"]):
        raise AcceptanceError(f"{workload} resource preflight must report warning/envelope_unmeasured with nonempty id and explanation: {assessment!r}")
    acknowledged = child.call("resources.acknowledge", {"assessment_id": assessment["assessment_id"]})
    if acknowledged != {"assessment_id": assessment["assessment_id"]}:
        raise AcceptanceError(f"{workload} resource acknowledgement did not echo the assessment_id: {acknowledged!r}")


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
    _acknowledge_resources(child, "live")
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
    _acknowledge_resources(child, "load")
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
    with EngineChild(
        executable, root, fixture, rate, channels,
        inference="deterministic", threads=1,
        scenario_timeout=SCENARIO_TIMEOUT_SECONDS, stdio_timeout=STDIO_TIMEOUT_SECONDS,
    ) as child:
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
    with EngineChild(
        executable, root, fixture, 16_000, 2,
        inference="deterministic", threads=1,
        scenario_timeout=SCENARIO_TIMEOUT_SECONDS, stdio_timeout=STDIO_TIMEOUT_SECONDS,
    ) as child:
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

    with EngineChild(
        executable, root, fixture, 16_000, 2,
        inference="deterministic", threads=1,
        scenario_timeout=SCENARIO_TIMEOUT_SECONDS, stdio_timeout=STDIO_TIMEOUT_SECONDS,
    ) as child:
        child.wait_ready()
        hello = child.call_empty("hello")
        if not isinstance(hello, dict) or not isinstance(hello.get("state"), dict):
            raise AcceptanceError(f"recovery hello returned an invalid state: {hello!r}")
        _read_settings(child)
        _acknowledge_resources(child, "load")
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
    with EngineChild(
        executable, root, fixture, 16_000, 2,
        inference="deterministic", threads=1,
        scenario_timeout=SCENARIO_TIMEOUT_SECONDS, stdio_timeout=STDIO_TIMEOUT_SECONDS,
    ) as child:
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
            timeout = min(child.stdio_timeout, child.remaining("oversized request termination"))
            try:
                code = child.process.wait(timeout=timeout)
            except subprocess.TimeoutExpired as error:
                raise AcceptanceError(f"oversized request did not terminate within {timeout:g}s") from error
            writer.join(timeout=child.stdio_timeout)
            if writer.is_alive():
                raise AcceptanceError(
                    f"oversized request writer did not stop within {child.stdio_timeout:g}s"
                )
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


PUBLISHED_SEGMENT_KEYS = {
    "segment_id", "source", "start_ms", "end_ms", "text", "display_text",
    "speakers", "clause_state", "clause_slices",
}
EXCLUDED_LINEAGE_FIELDS = (
    "source.segmentation_run_id", "source.asr_run_id", "source.asr_event_seq",
    "clause_slices[].reference.boundary_run_id", "clause_slices[].reference.clause_id",
)


def _load_process_recording_acceptance() -> Any:
    path = Path(__file__).resolve().parents[1] / "tools/linux-audio/process_recording_acceptance.py"
    spec = importlib.util.spec_from_file_location("process_recording_acceptance", path)
    if spec is None or spec.loader is None:
        raise AcceptanceError(f"cannot import ProcessRecording acceptance helper: {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _validate_speech_fixture(helper: Any, fixture: Path) -> tuple[int, int, str]:
    try:
        _, expected_sha256, expected_samples = helper.load_reference()
        duration_ms = helper.inspect_fixture(fixture, expected_sha256, expected_samples)
        # Python 3.12 wave reads PCM extensible; this acceptance input still requires PCM16.
        with wave.open(str(fixture), "rb") as audio:
            if audio.getcomptype() != "NONE":
                raise AcceptanceError(f"fixture must be uncompressed PCM, got {audio.getcomptype()!r}")
            if audio.getsampwidth() != 2:
                raise AcceptanceError(f"fixture must be PCM16, got {audio.getsampwidth() * 8}-bit")
            if audio.getnchannels() != 1 or audio.getframerate() != 16_000:
                raise AcceptanceError("fixture must be 16 kHz mono PCM16")
            frames = audio.getnframes()
            if frames <= 0 or frames != expected_samples:
                raise AcceptanceError(f"fixture must be nonempty and contain {expected_samples} frames, got {frames}")
    except (OSError, EOFError, wave.Error, helper.AcceptanceFailure) as error:
        raise AcceptanceError(f"invalid ProcessRecording reference fixture: {error}") from error
    return frames, duration_ms, expected_sha256


def _write_speech_inputs(
    fixture: Path, f32_path: Path, source_wav: Path, *, rate: int, channels: int
) -> int:
    """Convert bounded PCM16 packets; 48 kHz is explicit 3x repetition in both channels."""
    if (rate, channels) not in {(16_000, 1), (48_000, 2)}:
        raise AcceptanceError(f"unsupported speech fixture conversion {rate} Hz/{channels} channels")
    if f32_path.exists() or source_wav.exists():
        raise AcceptanceError("speech fixture output path already exists")
    frames_written = 0
    try:
        with wave.open(str(fixture), "rb") as source, f32_path.open("xb") as raw, wave.open(str(source_wav), "wb") as wav:
            if source.getcomptype() != "NONE" or source.getsampwidth() != 2:
                raise AcceptanceError("speech source changed after PCM16 validation")
            if source.getframerate() != 16_000 or source.getnchannels() != 1:
                raise AcceptanceError("speech source changed after 16 kHz mono validation")
            wav.setnchannels(channels)
            wav.setsampwidth(2)
            wav.setframerate(rate)
            while True:
                packet = source.readframes(2_048)
                if not packet:
                    break
                if len(packet) % 2:
                    raise AcceptanceError("PCM16 fixture ended with a partial sample")
                samples = list(struct.unpack("<" + "h" * (len(packet) // 2), packet))
                if not samples:
                    continue
                if rate == 16_000:
                    expanded = samples
                else:
                    expanded = [sample for sample in samples for _ in range(3) for _channel in range(2)]
                pcm = struct.pack("<" + "h" * len(expanded), *expanded)
                raw.write(struct.pack("<" + "f" * len(expanded), *(sample / 32_768 for sample in expanded)))
                wav.writeframesraw(pcm)
                frames_written += len(expanded) // channels
        if frames_written == 0:
            raise AcceptanceError("speech fixture conversion produced no frames")
    except (OSError, EOFError, wave.Error, struct.error) as error:
        raise AcceptanceError(f"cannot convert bounded PCM16 speech packets: {error}") from error
    if rate == 48_000 and frames_written % 3 != 0:
        raise AcceptanceError("explicit 48 kHz fixture upsampling produced a partial 3x group")
    return frames_written


def _validate_speech_flac_file(
    path: Path, source_frames: int, rate: int, context: str, *, expected_source_wav: Path | None
) -> dict[str, Any]:
    try:
        result = validate_flac(path)
    except (OSError, ValueError) as error:
        raise AcceptanceError(f"{context}: invalid FLAC at {path}: {error}") from error
    if result.get("sample_rate") != 16_000 or result.get("channels") != 1 or result.get("bits_per_sample") != 16:
        raise AcceptanceError(f"{context}: FLAC is not canonical mono 16 kHz/16-bit: {result!r}")
    samples = result.get("samples")
    if not isinstance(samples, list) or any(type(sample) is not int or not -32_768 <= sample <= 32_767 for sample in samples):
        raise AcceptanceError(f"{context}: decoder did not return finite signed-16-bit PCM samples")
    if result.get("sample_count") != len(samples):
        raise AcceptanceError(f"{context}: FLAC sample count and decoded PCM length disagree")
    if result.get("frame_count") != (len(samples) + 4_095) // 4_096:
        raise AcceptanceError(f"{context}: FLAC frame count does not match decoded PCM length")
    quotient, remainder = divmod(source_frames * 16_000, rate)
    permitted = {quotient, quotient + (1 if remainder else 0)}
    if len(samples) not in permitted:
        raise AcceptanceError(f"{context}: canonical sample count {len(samples)} is not in {sorted(permitted)}")
    if expected_source_wav is not None:
        if rate != 16_000:
            raise AcceptanceError(f"{context}: source-WAV identity comparison is only valid at 16 kHz")
        try:
            with wave.open(str(expected_source_wav), "rb") as source:
                if source.getcomptype() != "NONE" or source.getsampwidth() != 2:
                    raise AcceptanceError(f"{context}: expected source WAV is not uncompressed PCM16")
                if source.getframerate() != 16_000 or source.getnchannels() != 1:
                    raise AcceptanceError(f"{context}: expected source WAV is not 16 kHz mono")
                source_count = 0
                while True:
                    packet = source.readframes(2_048)
                    if not packet:
                        break
                    if len(packet) % 2:
                        raise AcceptanceError(f"{context}: expected source WAV ends with a partial PCM16 sample")
                    expected = struct.unpack("<" + "h" * (len(packet) // 2), packet)
                    for offset, sample in enumerate(expected):
                        index = source_count + offset
                        actual = samples[index] if index < len(samples) else None
                        if actual != sample:
                            raise AcceptanceError(
                                f"{context}: canonical PCM differs from source PCM16 at sample {index}: "
                                f"expected={sample} actual={actual}"
                            )
                    source_count += len(expected)
                if source_count != len(samples):
                    raise AcceptanceError(
                        f"{context}: canonical PCM sample count differs from source WAV: "
                        f"source={source_count} decoded={len(samples)}"
                    )
        except (OSError, EOFError, wave.Error) as error:
            raise AcceptanceError(f"{context}: cannot read exact PCM16 source WAV {expected_source_wav}: {error}") from error
    return result


def normalize_published_segments(segments: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Canonicalize only schema-known run/event/clause identity fields."""
    normalized = copy.deepcopy(segments)
    if any(not isinstance(segment, dict) or set(segment) != PUBLISHED_SEGMENT_KEYS for segment in normalized):
        raise AcceptanceError("published segments do not match the explicit materialized-segment schema")
    segmentation_runs: set[str] = set()
    asr_runs: set[str] = set()
    boundary_runs: set[str] = set()
    clause_aliases: dict[str, str] = {}
    for segment in normalized:
        source = segment["source"]
        if not isinstance(source, dict) or set(source) != {
            "segmentation_run_id", "segment_id", "asr_run_id", "asr_event_seq"
        }:
            raise AcceptanceError(f"segment source does not match SegmentTextReference schema: {source!r}")
        if not isinstance(source["segmentation_run_id"], str) or not source["segmentation_run_id"]:
            raise AcceptanceError("source.segmentation_run_id must be nonempty text")
        if not isinstance(source["asr_run_id"], str) or not source["asr_run_id"]:
            raise AcceptanceError("source.asr_run_id must be nonempty text")
        if type(source["asr_event_seq"]) is not int or source["asr_event_seq"] <= 0:
            raise AcceptanceError("source.asr_event_seq must be a positive integer")
        if source["segment_id"] != segment["segment_id"]:
            raise AcceptanceError("source.segment_id must match and preserve the published segment_id")
        segmentation_runs.add(source["segmentation_run_id"])
        asr_runs.add(source["asr_run_id"])
        slices = segment["clause_slices"]
        if not isinstance(slices, list):
            raise AcceptanceError("clause_slices must be an array")
        for clause_slice in slices:
            if not isinstance(clause_slice, dict) or set(clause_slice) != {
                "reference", "source_range", "priority", "needs_retry"
            }:
                raise AcceptanceError(f"clause slice does not match ClauseRowSlice schema: {clause_slice!r}")
            reference = clause_slice["reference"]
            if not isinstance(reference, dict) or set(reference) != {"boundary_run_id", "clause_id"}:
                raise AcceptanceError(f"clause reference does not match ClauseReference schema: {reference!r}")
            boundary_id, clause_id = reference["boundary_run_id"], reference["clause_id"]
            if not isinstance(boundary_id, str) or not boundary_id or not isinstance(clause_id, str) or not clause_id:
                raise AcceptanceError("clause run and derived clause IDs must be nonempty text")
            boundary_runs.add(boundary_id)
            if clause_id not in clause_aliases:
                clause_aliases[clause_id] = f"derived-clause-{len(clause_aliases) + 1}"
            reference["boundary_run_id"] = "<boundary-run>"
            reference["clause_id"] = clause_aliases[clause_id]
        source["segmentation_run_id"] = "<segmentation-run>"
        source["asr_run_id"] = "<asr-run>"
        source["asr_event_seq"] = "<asr-event-sequence>"
    if len(segmentation_runs) != 1 or len(asr_runs) != 1 or len(boundary_runs) != 1:
        raise AcceptanceError(
            "published segments must reference exactly one active segmentation, ASR, and boundary run; "
            f"got {len(segmentation_runs)}, {len(asr_runs)}, {len(boundary_runs)}"
        )
    return normalized


def _semantic_differences(left: Any, right: Any, path: str = "segments") -> list[tuple[str, Any, Any]]:
    if type(left) is not type(right):
        return [(path, left, right)]
    if isinstance(left, dict):
        differences: list[tuple[str, Any, Any]] = []
        for key in sorted(set(left) | set(right)):
            if key not in left or key not in right:
                differences.append((f"{path}.{key}", left.get(key), right.get(key)))
            else:
                differences.extend(_semantic_differences(left[key], right[key], f"{path}.{key}"))
        return differences
    if isinstance(left, list):
        differences = []
        for index in range(max(len(left), len(right))):
            if index >= len(left) or index >= len(right):
                differences.append((f"{path}[{index}]", left[index] if index < len(left) else None,
                                   right[index] if index < len(right) else None))
            else:
                differences.extend(_semantic_differences(left[index], right[index], f"{path}[{index}]"))
        return differences
    return [] if left == right else [(path, left, right)]


def _semantic_field_count(value: Any) -> int:
    if isinstance(value, dict):
        return sum(_semantic_field_count(child) for child in value.values())
    if isinstance(value, list):
        return sum(_semantic_field_count(child) for child in value)
    return 1


def _compared_semantic_field_count(normalized: list[dict[str, Any]]) -> int:
    semantic = copy.deepcopy(normalized)
    for segment in semantic:
        source = segment["source"]
        for key in ("segmentation_run_id", "asr_run_id", "asr_event_seq"):
            source.pop(key)
        for clause_slice in segment["clause_slices"]:
            reference = clause_slice["reference"]
            reference.pop("boundary_run_id")
            reference.pop("clause_id")
    return _semantic_field_count(semantic)


def compare_published_segments(
    baseline: list[dict[str, Any]], host: list[dict[str, Any]]
) -> dict[str, int]:
    normalized_baseline = normalize_published_segments(baseline)
    normalized_host = normalize_published_segments(host)
    differences = _semantic_differences(normalized_baseline, normalized_host)
    mismatched_segments = sum(
        bool(_semantic_differences(
            normalized_baseline[index] if index < len(normalized_baseline) else None,
            normalized_host[index] if index < len(normalized_host) else None,
            f"segments[{index}]",
        ))
        for index in range(max(len(normalized_baseline), len(normalized_host)))
    )
    text_mismatches = sum(
        baseline[index].get(key) != host[index].get(key)
        for index in range(min(len(baseline), len(host)))
        for key in ("text", "display_text")
    ) + abs(len(baseline) - len(host))
    if differences:
        path, left, right = differences[0]
        raise AcceptanceError(
            f"semantic comparison failed: segment_mismatches={mismatched_segments} "
            f"field_mismatches={len(differences)} text_mismatches={text_mismatches} "
            f"first_differing_field={path} "
            f"baseline={left!r} host={right!r}"
        )
    return {
        "segment_count": len(baseline), "segment_mismatches": 0,
        "text_mismatches": 0, "semantic_fields": _compared_semantic_field_count(normalized_baseline),
    }


def _resolve_executable(candidate: Path) -> Path:
    if not candidate.exists() or not candidate.is_file():
        raise AcceptanceError(f"--executable must identify an existing file: {candidate}")
    executable = candidate.resolve(strict=True)
    if not executable.is_file():
        raise AcceptanceError(f"resolved --executable is not a regular file: {executable}")
    if os.name != "nt" and not os.access(executable, os.X_OK):
        raise AcceptanceError(f"--executable is not executable: {executable}")
    return executable


def _full_model_settings(asr_size: str, threads: int) -> dict[str, Any]:
    return {
        "schema_version": 2,
        "source": "microphone",
        "device": {"kind": "default"},
        "asr_size": asr_size,
        "execution_provider": {"kind": "cpu"},
        "threads": threads,
        "low_heat": False,
        "decisions_enabled": True,
        "automatic_export": False,
        "export_destination_path": None,
    }


def _read_transcript_rows(child: EngineChild, session_id: str) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    cursor: Any = None
    seen_cursors: set[str] = set()
    while True:
        result = child.call(
            "transcript.read",
            {"session_id": session_id, "revision": None, "cursor": cursor, "limit": 200},
        )
        if not isinstance(result, dict) or result.get("session_id") != session_id:
            raise AcceptanceError(f"transcript.read returned the wrong session: {result!r}")
        page = result.get("rows")
        if not isinstance(page, list) or any(not isinstance(row, dict) for row in page):
            raise AcceptanceError(f"transcript.read returned invalid rows: {page!r}")
        rows.extend(page)
        next_cursor = result.get("next_cursor")
        if next_cursor is None:
            return rows
        if not isinstance(next_cursor, str) or not next_cursor or next_cursor in seen_cursors:
            raise AcceptanceError(f"transcript.read returned an invalid or repeated cursor: {next_cursor!r}")
        seen_cursors.add(next_cursor)
        cursor = next_cursor


def _format_transcript_rows(rows: list[dict[str, Any]]) -> bytes:
    lines: list[str] = []
    for row in rows:
        start = row.get("start_ms")
        headings = row.get("headings")
        text = row.get("text")
        if type(start) is not int or start < 0 or not isinstance(headings, list) or not headings:
            raise AcceptanceError(f"transcript row lacks a valid start time or speaker headings: {row!r}")
        if any(not isinstance(label, str) or not label for label in headings) or not isinstance(text, str):
            raise AcceptanceError(f"transcript row has invalid headings or text: {row!r}")
        total_seconds = start // 1000
        timestamp = f"{total_seconds // 60:02d}:{total_seconds % 60:02d}"
        single_line = re.sub(r"\r\n|[\r\n\u2028\u2029]", " ", text)
        lines.append(f"[{timestamp}] {' / '.join(headings)}: {single_line}\n")
    return "".join(lines).encode("utf-8")


def _project_baseline_rows(helper: Any, segments: list[dict[str, Any]]) -> list[dict[str, Any]]:
    labels = helper.make_speaker_labels(segments)
    projected: list[dict[str, Any]] = []
    for segment in segments:
        text = segment["display_text"]
        if not text.strip():
            continue
        projected.append({
            "start_ms": segment["start_ms"],
            "end_ms": segment["end_ms"],
            "text": text,
            "headings": helper.turn_labels(segment, labels),
        })
    return projected


def _compare_projected_rows(
    projected: list[dict[str, Any]], actual_rows: list[dict[str, Any]], context: str
) -> None:
    actual = [
        {key: row.get(key) for key in ("start_ms", "end_ms", "text", "headings")}
        for row in actual_rows
    ]
    differences = _semantic_differences(projected, actual, "transcript_rows")
    if differences:
        path, left, right = differences[0]
        raise AcceptanceError(
            f"{context}: display projection mismatch count={len(differences)} "
            f"first_differing_field={path} projected={left!r} transcript.read={right!r}"
        )


def _run_process_recording(
    arguments: list[str], environment: dict[str, str], label: str
) -> subprocess.CompletedProcess[str]:
    try:
        result = subprocess.run(
            arguments,
            env=environment,
            capture_output=True,
            text=True,
            encoding="utf-8",
            timeout=FULL_MODEL_SCENARIO_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired as error:
        raise AcceptanceError(f"{label} timed out after {FULL_MODEL_SCENARIO_TIMEOUT_SECONDS:g}s") from error
    if result.returncode != 0:
        raise AcceptanceError(
            f"{label} exited with {result.returncode}\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )
    return result


def _baseline_process_recording_command(
    executable: Path,
    sessions_root: Path,
    source_wav: Path,
    output: Path,
    threads: int,
    *,
    windows: bool,
) -> list[str]:
    return [
        str(executable), "--sessions-root", _process_recording_path(sessions_root, windows=windows),
        "--keep-session", "--with-decisions", "--threads", str(threads),
        _process_recording_path(source_wav, windows=windows),
        _process_recording_path(output, windows=windows),
    ]


def _host_resume_process_recording_command(
    executable: Path,
    session_id: str,
    sessions_root: Path,
    output: Path,
    threads: int,
    *,
    windows: bool,
) -> list[str]:
    return [
        str(executable), "--resume-session", session_id, "--sessions-root",
        _process_recording_path(sessions_root, windows=windows),
        "--with-decisions", "--threads", str(threads),
        _process_recording_path(output, windows=windows),
    ]


def _check_process_recording_provenance(
    helper: Any, session: Path, segments: list[dict[str, Any]], expected_model: str, threads: int
) -> None:
    events = helper.read_events(session)
    metadata = helper.load_json(session / "processing_metadata.json")
    run_ids = helper.check_runs(events, metadata, expected_model, threads)
    helper.check_export_matches_events(segments, events, run_ids["asr"])


def run_full_model_scenario(
    executable: Path,
    process_recording: Path,
    fixture: Path,
    source_wav: Path,
    source_frames: int,
    rate: int,
    channels: int,
    duration_ms: int,
    threads: int,
    helper: Any,
    environment: dict[str, str],
    expected_model: str,
    asr_size: str,
    label: str,
    owner: Path,
) -> dict[str, Any]:
    root = _make_root(owner, f"{label}-engine-root")
    settings = _full_model_settings(asr_size, threads)
    engine_session_dir: Path
    session_id: str
    transcript_rows: list[dict[str, Any]]
    retained: dict[str, Any]
    events_before: bytes
    metadata_before: bytes
    export_text: bytes
    with EngineChild(
        executable, root, fixture, rate, channels,
        inference="portable", threads=threads,
        scenario_timeout=FULL_MODEL_SCENARIO_TIMEOUT_SECONDS,
        stdio_timeout=FULL_MODEL_STDIO_TIMEOUT_SECONDS,
    ) as child:
        child.wait_ready()
        hello = child.call_empty("hello")
        if not isinstance(hello, dict) or not isinstance(hello.get("state"), dict):
            raise AcceptanceError(f"{label}: hello returned an invalid ready state: {hello!r}")
        replaced = child.call("settings.replace", {"expected_revision": None, "settings": settings})
        if not isinstance(replaced, dict) or replaced.get("settings") != settings:
            raise AcceptanceError(f"{label}: settings.replace did not echo every required setting: {replaced!r}")
        _acknowledge_resources(child, "load")
        prepared = child.call_empty("models.prepare")
        if not isinstance(prepared, dict):
            raise AcceptanceError(f"{label}: models.prepare returned an invalid result: {prepared!r}")
        _wait_for_recovery(child)
        session_id = _start_recording(child)
        recording_rows = _list_sessions(child)
        active = [row for row in recording_rows if row.get("session_id") == session_id]
        if len(active) != 1 or active[0].get("status") != "recording":
            raise AcceptanceError(f"{label}: recording catalog entry was not unique and recording: {recording_rows!r}")
        _paths_for_session(root, _required_folder_id(active[0], f"{label} recording catalog row"))
        stop = child.call("recording.stop", {"session_id": session_id})
        if not isinstance(stop, dict) or stop.get("session_id") != session_id:
            raise AcceptanceError(f"{label}: recording.stop returned the wrong session: {stop!r}")
        finalized = _wait_finalized(child, session_id, FULL_MODEL_FINALIZATION_TIMEOUT_SECONDS)
        engine_session_dir = _paths_for_session(root, _required_folder_id(finalized, f"{label} finalized catalog row"))
        state = child.call_empty("state.get")
        if not isinstance(state, dict) or state.get("queue") != []:
            raise AcceptanceError(f"{label}: processing queue was not empty after finalization: {state!r}")
        transcript_rows = _read_transcript_rows(child, session_id)
        retained = _validate_speech_flac_file(
            engine_session_dir / "audio" / "recording.flac", source_frames, rate,
            f"{label} retained recording", expected_source_wav=source_wav if rate == 16_000 else None,
        )
        export_destination = owner / f"{label}-exports"
        first_bundle: dict[str, bytes] | None = None
        for export_number in (1, 2):
            result = child.call(
                "session.export", {"session_id": session_id, "destination_path": str(export_destination)}
            )
            if not isinstance(result, dict) or result.get("session_id") != session_id:
                raise AcceptanceError(f"{label}: session.export #{export_number} returned invalid data: {result!r}")
            if not isinstance(result.get("destination_path"), str):
                raise AcceptanceError(f"{label}: session.export #{export_number} omitted destination_path")
            bundle = _resolve_path(Path(_extended_path_spelling(result["destination_path"])), strict=True)
            expected_bundle = _resolve_path(export_destination / engine_session_dir.name, strict=True)
            if bundle != expected_bundle:
                raise AcceptanceError(f"{label}: export wrote to {bundle}, expected {expected_bundle}")
            names = sorted(path.name for path in bundle.iterdir())
            if names != ["audio.flac", "transcript.txt"]:
                raise AcceptanceError(f"{label}: export bundle names differ: {names!r}")
            audio_path = bundle / "audio.flac"
            exported = _validate_speech_flac_file(
                audio_path, source_frames, rate, f"{label} exported FLAC #{export_number}",
                expected_source_wav=source_wav if rate == 16_000 else None,
            )
            retained_path = engine_session_dir / "audio" / "recording.flac"
            if audio_path.read_bytes() != retained_path.read_bytes():
                raise AcceptanceError(f"{label}: exported FLAC is not byte-identical to retained FLAC")
            if exported["samples"] != retained["samples"]:
                raise AcceptanceError(f"{label}: exported decoded PCM differs from retained PCM")
            exported_text = (bundle / "transcript.txt").read_bytes()
            if exported_text != _format_transcript_rows(transcript_rows):
                raise AcceptanceError(f"{label}: transcript.txt differs from formatted transcript.read rows")
            bundle_bytes = {name: (bundle / name).read_bytes() for name in names}
            if first_bundle is None:
                first_bundle = bundle_bytes
                export_text = exported_text
            elif bundle_bytes != first_bundle:
                raise AcceptanceError(f"{label}: repeated export changed bundle bytes")
        events_path = engine_session_dir / "events.jsonl"
        metadata_path = engine_session_dir / "processing_metadata.json"
        events_before = events_path.read_bytes()
        metadata_before = metadata_path.read_bytes()
        child.call_empty("shutdown")
        child.wait_for_exit(0, f"{label} shutdown")

    baseline_sessions = owner / f"{label}-baseline-sessions"
    baseline_sessions.mkdir()
    baseline_output = owner / f"{label}-baseline-segments.json"
    process_recording_windows = sys.platform == "win32"
    baseline_command = _baseline_process_recording_command(
        process_recording, baseline_sessions, source_wav, baseline_output, threads,
        windows=process_recording_windows,
    )
    baseline_result = _run_process_recording(baseline_command, environment, f"{label} baseline CLI")
    baseline_id = helper.parse_session_id(baseline_result.stdout)
    baseline_session_dir = helper.find_session_directory(baseline_sessions, baseline_id)
    baseline_segments = helper.read_segments(baseline_output)
    helper.check_segments(baseline_segments, duration_ms)
    helper.check_speakers(baseline_segments, duration_ms)
    _check_process_recording_provenance(helper, baseline_session_dir, baseline_segments, expected_model, threads)

    host_output = owner / f"{label}-host-resume-segments.json"
    host_sessions = root / "mac-ambient-jev" / "sessions"
    host_command = _host_resume_process_recording_command(
        process_recording, session_id, host_sessions, host_output, threads,
        windows=process_recording_windows,
    )
    _run_process_recording(host_command, environment, f"{label} host read-only resume")
    if (engine_session_dir / "events.jsonl").read_bytes() != events_before:
        raise AcceptanceError(f"{label}: host resume changed events.jsonl; it must only materialize published events")
    if (engine_session_dir / "processing_metadata.json").read_bytes() != metadata_before:
        raise AcceptanceError(f"{label}: host resume changed processing_metadata.json")
    host_segments = helper.read_segments(host_output)
    helper.check_segments(host_segments, duration_ms)
    helper.check_speakers(host_segments, duration_ms)
    _check_process_recording_provenance(helper, engine_session_dir, host_segments, expected_model, threads)
    comparison = compare_published_segments(baseline_segments, host_segments)
    _compare_projected_rows(
        _project_baseline_rows(helper, baseline_segments), transcript_rows,
        f"{label} baseline projection versus host transcript.read",
    )

    raw_characters = sum(len(segment["text"]) for segment in baseline_segments)
    display_characters = sum(len(segment["display_text"]) for segment in baseline_segments)
    print(
        f"scenario={label} source_frames={source_frames} canonical_samples={retained['sample_count']} "
        f"flac_frames={retained['frame_count']} pcm_md5={retained['md5']} threads={threads} "
        f"segments={comparison['segment_count']} baseline_segments={len(baseline_segments)} "
        f"host_segments={len(host_segments)} raw_text_characters={raw_characters} "
        f"display_text_characters={display_characters} text_mismatches={comparison['text_mismatches']} "
        f"segment_mismatches={comparison['segment_mismatches']} "
        f"compared_semantic_fields={comparison['semantic_fields']} "
        f"excluded_lineage_fields={','.join(EXCLUDED_LINEAGE_FIELDS)} transcript_bytes={len(export_text)}"
    )
    return retained


def run_full_model(
    executable: Path, process_recording: Path, fixture: Path, threads: int
) -> None:
    if not (sys.platform.startswith("linux") or sys.platform == "win32"):
        raise AcceptanceError(f"full-model portable acceptance is unavailable on {sys.platform}; Mac is not portable")
    helper = _load_process_recording_acceptance()
    try:
        environment = os.environ.copy()
        models = helper.require_model_environment(environment)
        fixture_frames, duration_ms, _ = _validate_speech_fixture(helper, fixture)
        executable = _resolve_executable(executable)
        process_recording = helper.require_executable(process_recording.resolve(strict=True), "ProcessRecording executable")
        expected_model = helper.expected_asr_model(models[helper.QWEN3_SIZE_VARIABLE])
    except helper.AcceptanceFailure as error:
        raise AcceptanceError(str(error)) from error
    if threads <= 0:
        raise AcceptanceError("--threads must be a positive integer")
    asr_size = models[helper.QWEN3_SIZE_VARIABLE]
    temporary_parent: str | None = None
    if os.name == "nt":
        temporary_parent = str(_resolve_path(Path(tempfile.gettempdir()), strict=True))
    with tempfile.TemporaryDirectory(prefix="portable speech acceptance ", dir=temporary_parent) as temporary:
        owner = _resolve_path(Path(_extended_path_spelling(temporary)), strict=True)
        fixture_directory = owner / "fixtures"
        fixture_directory.mkdir()
        scenarios = [(16_000, 1, "speech-16000-mono")]
        if sys.platform == "win32":
            scenarios.append((48_000, 2, "speech-48000-stereo-explicit-3x-upsampling"))
            print("fixture_upsampling=repeat_each_original_PCM16_sample_3_times_into_both_channels_for_source_input_only; capture_SRC=Windows_CanonicalAudioResampler")
        for rate, channels, label in scenarios:
            f32_path = fixture_directory / f"{label}.f32le"
            source_wav = fixture_directory / f"{label}.wav"
            source_frames = _write_speech_inputs(
                fixture, f32_path, source_wav, rate=rate, channels=channels
            )
            expected_source_frames = fixture_frames if rate == 16_000 else fixture_frames * 3
            if source_frames != expected_source_frames:
                raise AcceptanceError(
                    f"{label}: generated source frame count {source_frames} differs from pinned fixture-derived "
                    f"count {expected_source_frames}"
                )
            run_full_model_scenario(
                executable, process_recording, f32_path, source_wav, source_frames,
                rate, channels, duration_ms, threads, helper,
                environment, expected_model, asr_size, label, owner,
            )
    print("acceptance=passed")


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


def positive_int(value: str) -> int:
    if not value or not value.isascii() or not value.isdecimal():
        raise argparse.ArgumentTypeError("must be a positive decimal integer")
    try:
        parsed = int(value, 10)
    except ValueError as error:
        raise argparse.ArgumentTypeError("must be a positive decimal integer") from error
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be a positive decimal integer")
    return parsed


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    deterministic = commands.add_parser("deterministic", help="run the existing deterministic harness scenarios")
    deterministic.add_argument("--executable", type=Path, required=True, help="engine harness executable")
    full_model = commands.add_parser("full-model", help="compare portable live recording with ProcessRecording")
    full_model.add_argument("--executable", type=Path, required=True, help="engine harness executable")
    full_model.add_argument("--process-recording", type=Path, required=True, help="ProcessRecording executable")
    full_model.add_argument("--fixture", type=Path, required=True, help="pinned 16 kHz mono PCM16 fixture")
    full_model.add_argument("--threads", type=positive_int, required=True, help="portable inference thread count")
    return parser


def main(argv: list[str] | None = None) -> int:
    try:
        arguments = build_parser().parse_args(sys.argv[1:] if argv is None else argv)
        if arguments.command == "deterministic":
            run(_resolve_executable(arguments.executable))
        elif arguments.command == "full-model":
            run_full_model(
                arguments.executable, arguments.process_recording, arguments.fixture, arguments.threads
            )
        else:
            raise AcceptanceError(f"unsupported acceptance subcommand: {arguments.command!r}")
    except AcceptanceError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    except Exception as error:
        print(f"ERROR: unexpected {type(error).__name__}: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
