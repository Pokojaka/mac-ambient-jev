#!/usr/bin/env python3
"""Report suite and function timing from Swift Testing JSON event streams."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
import math
from pathlib import Path
import sys
from typing import Any

SUITE_BUDGET_SECONDS = 540

KNOWN_EVENT_KINDS = frozenset(
    {
        "runStarted",
        "runEnded",
        "testStarted",
        "testEnded",
        "testSkipped",
        "testCaseStarted",
        "testCaseEnded",
        "issueRecorded",
        "valueAttached",
    }
)


class EventStreamError(ValueError):
    """An event stream is unreadable or violates the supported ABI schema."""


@dataclass(frozen=True)
class TestRecord:
    identifier: str
    kind: str
    name: str
    source_file: str
    source_line: int


@dataclass(frozen=True)
class Event:
    kind: str
    instant: float
    test_identifier: str | None


@dataclass(frozen=True)
class RunSegment:
    started: float
    ended: float | None


@dataclass(frozen=True)
class EventStream:
    tests: dict[str, TestRecord]
    events: tuple[Event, ...]


@dataclass(frozen=True)
class FunctionTiming:
    test: TestRecord
    started: float
    ended: float

    @property
    def duration(self) -> float:
        return self.ended - self.started


def _test_identifier(value: Any, location: str) -> str:
    if not isinstance(value, str) or not value:
        raise EventStreamError(f"{location}: ID must be a nonempty string")
    return value


def _finite_seconds(value: Any, location: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise EventStreamError(f"{location}: expected a finite numeric timestamp")
    try:
        seconds = float(value)
    except (OverflowError, ValueError) as error:
        raise EventStreamError(f"{location}: expected a finite numeric timestamp") from error
    if not math.isfinite(seconds):
        raise EventStreamError(f"{location}: expected a finite numeric timestamp")
    return seconds


def _reject_json_constant(value: str) -> None:
    raise ValueError(f"non-finite JSON number {value}")


def _object(value: Any, location: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise EventStreamError(f"{location}: expected an object")
    return value


def parse_event_stream(path: Path) -> EventStream:
    """Parse and validate a Swift Testing JSONL stream using ABI version 0."""
    path = Path(path)
    try:
        contents = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise EventStreamError(f"cannot read event file {path}: {error}") from error
    if not contents.strip():
        raise EventStreamError(f"event file {path} is empty")

    tests: dict[str, TestRecord] = {}
    events: list[Event] = []
    for line_number, line in enumerate(contents.splitlines(), start=1):
        location = f"{path}:{line_number}"
        if not line.strip():
            raise EventStreamError(f"{location}: blank line is not a JSONL record")
        try:
            record_value = json.loads(line, parse_constant=_reject_json_constant)
        except (json.JSONDecodeError, ValueError) as error:
            raise EventStreamError(f"{location}: malformed JSON: {error}") from error
        record = _object(record_value, location)
        version = record.get("version")
        if type(version) is not int or version != 0:
            raise EventStreamError(f"{location}: unsupported or missing event stream version {version!r}")
        record_kind = record.get("kind")
        if not isinstance(record_kind, str):
            raise EventStreamError(f"{location}: record kind must be a string")

        if record_kind == "test":
            payload = _object(record.get("payload"), f"{location} payload")
            identifier = _test_identifier(payload.get("id"), f"{location} test id")
            test_kind = payload.get("kind")
            if test_kind not in ("function", "suite"):
                raise EventStreamError(f"{location}: test kind must be 'function' or 'suite'")
            name = payload.get("name")
            if not isinstance(name, str):
                raise EventStreamError(f"{location}: test name must be a string")
            source = _object(payload.get("sourceLocation"), f"{location} sourceLocation")
            source_file = source.get("fileID")
            source_line = source.get("line")
            if not isinstance(source_file, str):
                raise EventStreamError(f"{location}: sourceLocation.fileID must be a string")
            if type(source_line) is not int or source_line < 1:
                raise EventStreamError(f"{location}: sourceLocation.line must be a positive integer")
            if identifier in tests:
                raise EventStreamError(f"{location}: duplicate test id {identifier}")
            tests[identifier] = TestRecord(identifier, test_kind, name, source_file, source_line)
        elif record_kind == "event":
            payload = _object(record.get("payload"), f"{location} payload")
            event_kind = payload.get("kind")
            if not isinstance(event_kind, str):
                raise EventStreamError(f"{location}: event kind must be a string")
            if event_kind not in KNOWN_EVENT_KINDS:
                continue
            instant = _object(payload.get("instant"), f"{location} instant")
            timestamp = _finite_seconds(
                instant.get("absolute"), f"{location} instant.absolute"
            )
            if not isinstance(payload.get("messages"), list):
                raise EventStreamError(f"{location}: event messages must be an array")
            identifier: str | None = None
            if "testID" in payload:
                identifier = _test_identifier(payload["testID"], f"{location} testID")
            if event_kind in ("testStarted", "testEnded") and identifier is None:
                raise EventStreamError(f"{location}: {event_kind} requires testID")
            events.append(Event(event_kind, timestamp, identifier))
        # ABI-defined record kinds not consumed here are deliberately ignored.

    if not tests and not events:
        raise EventStreamError(f"event file {path} contains no supported records")

    for event in events:
        if event.test_identifier is not None and event.test_identifier not in tests:
            raise EventStreamError(
                f"event {event.kind} refers to unknown test id {event.test_identifier}"
            )
    return EventStream(tests, tuple(events))


def _event_segment_index(event: Event, segments: tuple[RunSegment, ...]) -> int:
    candidates = [
        index
        for index, segment in enumerate(segments)
        if event.instant >= segment.started
        and (segment.ended is None or event.instant <= segment.ended)
    ]
    if not candidates:
        raise EventStreamError(f"{event.kind} occurs outside every run segment")
    if len(candidates) != 1:
        raise EventStreamError(
            f"{event.kind} falls on a shared boundary between run segments"
        )
    return candidates[0]


def _event_times(
    events: tuple[Event, ...],
) -> tuple[tuple[RunSegment, ...], float, float | None, float]:
    lifecycle = sorted(
        (event for event in events if event.kind in ("runStarted", "runEnded")),
        key=lambda event: event.instant,
    )
    if not lifecycle:
        raise EventStreamError("event stream has no runStarted event")

    segments: list[RunSegment] = []
    active_start: float | None = None
    times: dict[float, list[str]] = {}
    for event in lifecycle:
        times.setdefault(event.instant, []).append(event.kind)

    for instant in sorted(times):
        kinds = times[instant]
        starts = kinds.count("runStarted")
        ends = kinds.count("runEnded")
        if starts > 1:
            raise EventStreamError("duplicate runStarted without closing the previous run")
        if ends > 1:
            raise EventStreamError("duplicate runEnded")

        if active_start is not None:
            if ends:
                if instant < active_start:
                    raise EventStreamError(
                        "runEnded precedes runStarted (negative suite interval)"
                    )
                segments.append(RunSegment(active_start, instant))
                active_start = None
            if starts:
                if active_start is not None:
                    raise EventStreamError(
                        "overlapping or nested runStarted before the previous runEnded"
                    )
                active_start = instant
        elif starts:
            active_start = instant
            if ends:
                segments.append(RunSegment(active_start, instant))
                active_start = None
        elif ends:
            if not segments and any(later > instant for later in times):
                raise EventStreamError(
                    "unmatched runEnded precedes runStarted (negative suite interval)"
                )
            raise EventStreamError("unmatched runEnded")

    if not segments and active_start is None:
        raise EventStreamError("event stream has no runStarted event")
    if active_start is not None:
        segments.append(RunSegment(active_start, None))

    run_segments = tuple(segments)
    run_started = run_segments[0].started
    run_ended = run_segments[-1].ended
    for event in events:
        if event.kind not in ("runStarted", "runEnded"):
            _event_segment_index(event, run_segments)

    last_instant = max(event.instant for event in events)
    if not math.isfinite(last_instant - run_started):
        raise EventStreamError("observed whole-invocation interval is not finite")
    return run_segments, run_started, run_ended, last_instant


def _function_timings(
    stream: EventStream,
    run_segments: tuple[RunSegment, ...],
) -> tuple[list[FunctionTiming], dict[str, float], bool]:
    starts: dict[str, tuple[float, int]] = {}
    ends: dict[str, tuple[float, int]] = {}
    for event in stream.events:
        if event.kind not in ("testStarted", "testEnded"):
            continue
        identifier = event.test_identifier
        if identifier is None:
            raise EventStreamError(f"{event.kind} is missing testID")
        target = starts if event.kind == "testStarted" else ends
        if identifier in target:
            raise EventStreamError(f"duplicate {event.kind} for test id {identifier}")
        target[identifier] = (event.instant, _event_segment_index(event, run_segments))

    timings: list[FunctionTiming] = []
    for identifier, (ended, ended_segment) in ends.items():
        if identifier not in starts:
            raise EventStreamError(f"testEnded has no testStarted for test id {identifier}")
        started, started_segment = starts[identifier]
        if ended < started:
            raise EventStreamError(f"testEnded precedes testStarted for test id {identifier}")
        if started_segment != ended_segment:
            raise EventStreamError(
                f"testStarted and testEnded occur in different run segments for test id {identifier}"
            )
        test = stream.tests[identifier]
        if test.kind == "function":
            timings.append(FunctionTiming(test, started, ended))

    unfinished = {
        identifier: started
        for identifier, (started, _) in starts.items()
        if identifier not in ends
    }
    return timings, unfinished, bool(unfinished)


def _print_function_timings(
    timings: list[FunctionTiming],
    unfinished: dict[str, float],
    tests: dict[str, TestRecord],
    run_started: float,
    observed_through: float,
    *,
    include_unfinished: bool,
) -> None:
    ordered = sorted(timings, key=lambda item: (-item.duration, item.test.identifier))
    print("Top 20 function tests by elapsed event time:")
    if not ordered:
        print("  No completed function tests.")
    for rank, timing in enumerate(ordered[:20], start=1):
        test = timing.test
        print(
            f"  {rank:2d}. {timing.duration:.3f}s | id={test.identifier} | "
            f"{test.source_file}:{test.source_line} | "
            f"start=+{timing.started - run_started:.3f}s "
            f"end=+{timing.ended - run_started:.3f}s"
        )
    if include_unfinished:
        print("Unfinished function tests (observed lower bounds):")
        function_starts = [
            (tests[key], started)
            for key, started in unfinished.items()
            if tests[key].kind == "function"
        ]
        function_starts.sort(
            key=lambda item: (
                -(observed_through - item[1]),
                item[0].identifier,
            )
        )
        if not function_starts:
            print("  No unfinished function tests.")
        for test, started in function_starts:
            lower_bound = max(0.0, observed_through - started)
            print(
                f"  id={test.identifier} | {test.source_file}:{test.source_line} | "
                f"start=+{started - run_started:.3f}s | "
                f"observed lower bound={lower_bound:.3f}s"
            )


def report(path: Path, *, enforce_budget: bool) -> int:
    """Print a timing report and return nonzero for invalid or incomplete runs."""
    try:
        stream = parse_event_stream(path)
        run_segments, run_started, run_ended, last_instant = _event_times(
            stream.events
        )
        timings, unfinished, has_unfinished = _function_timings(stream, run_segments)
    except EventStreamError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1

    print(f"Run segments: {len(run_segments)}")
    incomplete = run_ended is None
    suite_wall: float | None = None
    if incomplete:
        observed_lower_bound = max(0.0, last_instant - run_started)
        print("Whole-invocation envelope: INCOMPLETE")
        print(
            f"Observed whole-invocation lower bound: {observed_lower_bound:.3f}s "
            "(latest observed event minus earliest runStarted; includes inter-product "
            "gaps, queue wait, not CPU time)"
        )
        observed_through = last_instant
    else:
        suite_wall = run_ended - run_started
        print(
            f"Whole-invocation envelope: {suite_wall:.3f}s "
            "(latest runEnded.absolute - earliest runStarted.absolute; includes "
            "inter-product gaps, queue wait, not CPU time)"
        )
        observed_through = run_ended

    print(
        "Parameterized function durations are aggregate envelopes; Swift Testing ABI v0 "
        "has no usable per-case identity, so per-case durations are not reported."
    )
    if enforce_budget:
        if incomplete:
            print(f"Budget: {SUITE_BUDGET_SECONDS}s; FAIL (incomplete)")
        else:
            assert suite_wall is not None
            over_budget = suite_wall > SUITE_BUDGET_SECONDS
            qualifiers = []
            if over_budget:
                qualifiers.append("over budget")
            if has_unfinished:
                qualifiers.append("unfinished test events")
            status = "FAIL" if qualifiers else "PASS"
            detail = f" ({', '.join(qualifiers)})" if qualifiers else ""
            print(f"Budget: {SUITE_BUDGET_SECONDS}s; {status}{detail}")
    else:
        print("Budget: not applied (filtered run)")
        if incomplete or has_unfinished:
            failures = []
            if incomplete:
                failures.append("incomplete")
            if has_unfinished:
                failures.append("unfinished test events")
            print(f"Run status: FAIL ({', '.join(failures)})")
        else:
            print("Run status: PASS")

    _print_function_timings(
        timings,
        unfinished,
        stream.tests,
        run_started,
        observed_through,
        include_unfinished=incomplete or has_unfinished,
    )

    over_budget = (
        enforce_budget
        and suite_wall is not None
        and suite_wall > SUITE_BUDGET_SECONDS
    )
    if over_budget:
        sys.stdout.flush()
        print(
            f"ERROR: whole-invocation envelope measured {suite_wall:.3f} seconds "
            f"exceeds budget {SUITE_BUDGET_SECONDS} seconds",
            file=sys.stderr,
        )
    return int(incomplete or has_unfinished or over_budget)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("event_path", type=Path, metavar="EVENT_PATH")
    parser.add_argument("--filtered", action="store_true")
    arguments = parser.parse_args(argv)
    return report(arguments.event_path, enforce_budget=not arguments.filtered)


if __name__ == "__main__":
    raise SystemExit(main())
