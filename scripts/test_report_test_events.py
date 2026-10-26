#!/usr/bin/env python3
"""Synthetic checks for Swift Testing ABI v0 timing reports."""

from __future__ import annotations

import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest

from report_test_events import SUITE_BUDGET_SECONDS, report


def test_record(identifier: object, *, kind: str = "function", number: int = 1) -> dict[str, object]:
    return {
        "version": 0,
        "kind": "test",
        "payload": {
            "id": identifier,
            "kind": kind,
            "name": f"Fixture.test{number}",
            "sourceLocation": {"fileID": f"Tests/Fixture{number}.swift", "line": number},
        },
    }


def event_record(
    kind: str,
    instant: object,
    *,
    test_id: object | None = None,
    messages: list[object] | None = None,
) -> dict[str, object]:
    payload: dict[str, object] = {
        "kind": kind,
        "instant": {"absolute": instant},
        "messages": [] if messages is None else messages,
    }
    if test_id is not None:
        payload["testID"] = test_id
    return {"version": 0, "kind": "event", "payload": payload}


class TestEventReportTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.path = self.root / "events.jsonl"

    def write_records(self, records: list[dict[str, object]]) -> None:
        self.path.write_text(
            "".join(json.dumps(record, separators=(",", ":")) + "\n" for record in records),
            encoding="utf-8",
        )

    def run_report(self, *, enforce_budget: bool) -> tuple[int, str, str]:
        stdout = io.StringIO()
        stderr = io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            status = report(self.path, enforce_budget=enforce_budget)
        return status, stdout.getvalue(), stderr.getvalue()

    def test_uses_event_deltas_not_messages_or_epoch_values(self) -> None:
        identifier = "ExampleTests/ExampleSuite/test_uses_event_deltas_not_messages_or_epoch_values()"
        self.write_records(
            [
                event_record("testEnded", 1_700_000_008.5, test_id=identifier,
                             messages=["passed after 9000 seconds"]),
                test_record(identifier),
                event_record("runEnded", 1_700_000_015.0),
                event_record("testStarted", 1_700_000_005.0, test_id=identifier),
                event_record("runStarted", 1_700_000_000.0),
            ]
        )
        status, output, error = self.run_report(enforce_budget=True)
        self.assertEqual(status, 0, error)
        self.assertIn("Whole-invocation envelope: 15.000s", output)
        self.assertIn(
            "3.500s | id=ExampleTests/ExampleSuite/test_uses_event_deltas_not_messages_or_epoch_values()",
            output,
        )
        self.assertIn("start=+5.000s end=+8.500s", output)
        self.assertNotIn("9000", output)
        self.assertNotIn("1700000000", output)
        self.assertIn("inter-product gaps, queue wait, not CPU time", output)

    def test_ranks_only_top_twenty_functions_and_excludes_suites(self) -> None:
        records: list[dict[str, object]] = [
            test_record("suite", kind="suite", number=99),
            event_record("runStarted", 100.0),
        ]
        for number in range(1, 23):
            identifier = f"function-{number}"
            records.extend(
                [
                    test_record(identifier, number=number),
                    event_record("testStarted", 100.0, test_id=identifier),
                    event_record("testEnded", 100.0 + number, test_id=identifier),
                ]
            )
        records.extend(
            [
                event_record("testStarted", 100.0, test_id="suite"),
                event_record("testEnded", 130.0, test_id="suite"),
                event_record("runEnded", 140.0),
            ]
        )
        self.write_records(records)
        status, output, error = self.run_report(enforce_budget=True)
        self.assertEqual(status, 0, error)
        self.assertIn("1. 22.000s | id=function-22", output)
        self.assertIn("20. 3.000s | id=function-3", output)
        self.assertNotIn("id=function-2 |", output)
        self.assertNotIn("id=suite", output)
        self.assertEqual(sum(" | Tests/Fixture" in line for line in output.splitlines()), 20)

    def test_parameterized_case_events_are_not_paired_or_given_fake_durations(self) -> None:
        identifier = "parameterized-function"
        self.write_records(
            [
                test_record(identifier),
                event_record("runStarted", 10.0),
                event_record("testStarted", 12.0, test_id=identifier),
                event_record("testCaseStarted", 13.0, test_id=identifier),
                event_record("testCaseStarted", 14.0, test_id=identifier),
                event_record("testCaseEnded", 19.0, test_id=identifier),
                event_record("testCaseEnded", 20.0, test_id=identifier),
                event_record("testEnded", 22.0, test_id=identifier),
                event_record("runEnded", 25.0),
            ]
        )
        status, output, error = self.run_report(enforce_budget=True)
        self.assertEqual(status, 0, error)
        self.assertIn("10.000s | id=parameterized-function", output)
        self.assertIn("no usable per-case identity", output)
        self.assertNotIn("case 1", output.lower())
        self.assertNotIn("case #", output.lower())

    def test_issue_events_do_not_decide_success(self) -> None:
        self.write_records(
            [
                event_record("runStarted", 4.0),
                event_record("issueRecorded", 5.0, messages=["failed"]),
                event_record("runEnded", 7.0),
            ]
        )
        status, output, error = self.run_report(enforce_budget=True)
        self.assertEqual(status, 0, error)
        self.assertIn("Budget:", output)
        self.assertIn("PASS", output)

    def test_sequential_runs_include_inter_product_gaps_in_budget(self) -> None:
        self.write_records(
            [
                event_record("runStarted", 1.0),
                event_record("runEnded", 2.0),
                event_record("runStarted", SUITE_BUDGET_SECONDS + 1.0),
                event_record("runEnded", SUITE_BUDGET_SECONDS + 2.0),
            ]
        )
        status, output, error = self.run_report(enforce_budget=True)
        self.assertEqual(status, 1)
        self.assertIn(
            f"ERROR: whole-invocation envelope measured {SUITE_BUDGET_SECONDS + 1:.3f} "
            f"seconds exceeds budget {SUITE_BUDGET_SECONDS} seconds",
            error,
        )
        self.assertIn("Run segments: 2", output)
        self.assertIn(
            f"Whole-invocation envelope: {SUITE_BUDGET_SECONDS + 1:.3f}s", output
        )
        self.assertIn("includes inter-product gaps", output)
        self.assertIn(
            f"Budget: {SUITE_BUDGET_SECONDS}s; FAIL (over budget)", output
        )

    def test_out_of_order_multisegment_stream_uses_global_offsets(self) -> None:
        self.write_records(
            [
                test_record("first", number=1),
                test_record("second", number=2),
                event_record("testEnded", 35.0, test_id="second"),
                event_record("runEnded", 40.0),
                event_record("testStarted", 12.0, test_id="first"),
                event_record("runStarted", 30.0),
                event_record("testEnded", 14.0, test_id="first"),
                event_record("runEnded", 20.0),
                event_record("runStarted", 10.0),
                event_record("testStarted", 31.0, test_id="second"),
            ]
        )
        status, output, error = self.run_report(enforce_budget=True)
        self.assertEqual(status, 0, error)
        self.assertIn("Run segments: 2", output)
        self.assertIn("Whole-invocation envelope: 30.000s", output)
        self.assertIn("4.000s | id=second", output)
        self.assertIn("start=+21.000s end=+25.000s", output)
        self.assertIn("2.000s | id=first", output)
        self.assertIn("start=+2.000s end=+4.000s", output)

    def test_incomplete_final_segment_keeps_available_timings_and_unfinished(self) -> None:
        self.write_records(
            [
                test_record("completed", number=1),
                test_record("partial", number=2),
                event_record("runStarted", 10.0),
                event_record("testStarted", 11.0, test_id="completed"),
                event_record("testEnded", 12.0, test_id="completed"),
                event_record("runEnded", 20.0),
                event_record("runStarted", 100.0),
                event_record("testStarted", 101.0, test_id="partial"),
                event_record("issueRecorded", 105.0),
            ]
        )
        status, output, error = self.run_report(enforce_budget=True)
        self.assertEqual(status, 1)
        self.assertEqual(error, "")
        self.assertIn("Run segments: 2", output)
        self.assertIn("Whole-invocation envelope: INCOMPLETE", output)
        self.assertIn("Observed whole-invocation lower bound: 95.000s", output)
        self.assertIn("1.000s | id=completed", output)
        self.assertIn("id=partial", output)
        self.assertIn("observed lower bound=4.000s", output)

    def test_rejects_overlapping_runs_and_events_outside_segments(self) -> None:
        self.write_records(
            [
                event_record("runStarted", 1.0),
                event_record("runStarted", 2.0),
                event_record("runEnded", 3.0),
            ]
        )
        status, _, error = self.run_report(enforce_budget=True)
        self.assertEqual(status, 1)
        self.assertIn("overlapping or nested runStarted", error)

        self.write_records(
            [
                event_record("runStarted", 1.0),
                event_record("runEnded", 2.0),
                event_record("issueRecorded", 3.0),
                event_record("runStarted", 4.0),
                event_record("runEnded", 5.0),
            ]
        )
        status, _, error = self.run_report(enforce_budget=True)
        self.assertEqual(status, 1)
        self.assertIn("issueRecorded occurs outside every run segment", error)

    def test_rejects_test_pair_crossing_run_segments(self) -> None:
        self.write_records(
            [
                test_record("crossing"),
                event_record("runStarted", 1.0),
                event_record("testStarted", 1.5, test_id="crossing"),
                event_record("runEnded", 2.0),
                event_record("runStarted", 3.0),
                event_record("testEnded", 3.5, test_id="crossing"),
                event_record("runEnded", 4.0),
            ]
        )
        status, _, error = self.run_report(enforce_budget=True)
        self.assertEqual(status, 1)
        self.assertIn("different run segments", error)

    def test_incomplete_report_prints_completed_top_twenty_and_lower_bounds(self) -> None:
        records = [event_record("runStarted", 100.0)]
        for number in range(1, 23):
            identifier = f"done-{number}"
            records.extend(
                [
                    test_record(identifier, number=number),
                    event_record("testStarted", 101.0, test_id=identifier),
                    event_record("testEnded", 101.0 + number / 10, test_id=identifier),
                ]
            )
        records.extend(
            [
                test_record("running", number=23),
                event_record("testStarted", 106.0, test_id="running"),
                event_record("issueRecorded", 110.0, messages=["run failed"]),
            ]
        )
        self.write_records(records)

        status, output, error = self.run_report(enforce_budget=True)
        self.assertEqual(status, 1)
        self.assertEqual(error, "")
        self.assertIn("Whole-invocation envelope: INCOMPLETE", output)
        self.assertIn("Observed whole-invocation lower bound: 10.000s", output)
        self.assertIn("1. 2.200s | id=done-22", output)
        self.assertIn("20. 0.300s | id=done-3", output)
        self.assertNotIn("id=done-2 |", output)
        self.assertIn("id=running |", output)
        self.assertIn("observed lower bound=4.000s", output)
        self.assertIn(
            f"Budget: {SUITE_BUDGET_SECONDS}s; FAIL (incomplete)", output
        )
        self.assertEqual(sum(" | id=done-" in line for line in output.splitlines()), 20)

    def test_exact_budget_passes_and_over_budget_fails_after_printing_timings(self) -> None:
        for suite_wall, expected_status in (
            (SUITE_BUDGET_SECONDS, 0),
            (SUITE_BUDGET_SECONDS + 0.001, 1),
        ):
            with self.subTest(suite_wall=suite_wall):
                self.write_records(
                    [
                        test_record("budget-function"),
                        event_record("runStarted", 0.0),
                        event_record("testStarted", 1.0, test_id="budget-function"),
                        event_record("testEnded", 2.0, test_id="budget-function"),
                        event_record("runEnded", suite_wall),
                    ]
                )
                status, output, error = self.run_report(enforce_budget=True)
                self.assertEqual(status, expected_status, error)
                self.assertIn("FAIL" if expected_status else "PASS", output)
                self.assertIn("Top 20 function tests by elapsed event time:", output)
                self.assertIn("1. 1.000s | id=budget-function", output)
                if expected_status:
                    self.assertIn(
                        f"measured {suite_wall:.3f} seconds exceeds budget "
                        f"{SUITE_BUDGET_SECONDS} seconds",
                        error,
                    )
                else:
                    self.assertEqual(error, "")

    def test_filtered_run_does_not_fail_for_duration_over_budget(self) -> None:
        self.write_records(
            [
                event_record("runStarted", 0.0),
                event_record("runEnded", SUITE_BUDGET_SECONDS + 1.0),
            ]
        )

        status, output, error = self.run_report(enforce_budget=False)
        self.assertEqual(status, 0, error)
        self.assertIn("Budget: not applied (filtered run)", output)
        self.assertIn(
            f"Whole-invocation envelope: {SUITE_BUDGET_SECONDS + 1:.3f}s", output
        )
        self.assertIn("Run status: PASS", output)
        self.assertEqual(error, "")

    def test_filtered_runs_still_fail_for_incomplete_and_unfinished_streams(self) -> None:
        cases = (
            (
                [
                    event_record("runStarted", 0.0),
                    event_record("issueRecorded", SUITE_BUDGET_SECONDS + 1.0),
                ],
                "Run status: FAIL (incomplete)",
            ),
            (
                [
                    test_record("unfinished"),
                    event_record("runStarted", 0.0),
                    event_record("testStarted", 1.0, test_id="unfinished"),
                    event_record("runEnded", SUITE_BUDGET_SECONDS + 1.0),
                ],
                "Run status: FAIL (unfinished test events)",
            ),
        )
        for records, expected_status in cases:
            with self.subTest(expected_status=expected_status):
                self.write_records(records)
                status, output, error = self.run_report(enforce_budget=False)
                self.assertEqual(status, 1)
                self.assertIn("Budget: not applied (filtered run)", output)
                self.assertIn(expected_status, output)
                self.assertEqual(error, "")

    def test_filtered_runs_still_reject_malformed_and_missing_streams(self) -> None:
        self.path.write_text("{", encoding="utf-8")
        status, _, error = self.run_report(enforce_budget=False)
        self.assertEqual(status, 1)
        self.assertIn("malformed JSON", error)

        self.path.unlink()
        status, _, error = self.run_report(enforce_budget=False)
        self.assertEqual(status, 1)
        self.assertIn("cannot read event file", error)

    def test_rejects_non_string_and_empty_test_ids(self) -> None:
        for identifier in (7, {"opaque": "id"}, None, ""):
            with self.subTest(identifier=identifier):
                self.write_records(
                    [
                        test_record(identifier),
                        event_record("runStarted", 1.0),
                        event_record("runEnded", 2.0),
                    ]
                )
                status, _, error = self.run_report(enforce_budget=True)
                self.assertEqual(status, 1)
                self.assertIn("ID must be a nonempty string", error)

    def test_rejects_non_string_event_test_ids(self) -> None:
        self.write_records(
            [
                test_record("opaque-test-id"),
                event_record("runStarted", 1.0),
                event_record("testStarted", 1.5, test_id=7),
                event_record("runEnded", 2.0),
            ]
        )
        status, _, error = self.run_report(enforce_budget=True)
        self.assertEqual(status, 1)
        self.assertIn("ID must be a nonempty string", error)

    def test_requires_source_location_file_id_without_file_alias(self) -> None:
        self.write_records(
            [
                {
                    "version": 0,
                    "kind": "test",
                    "payload": {
                        "id": "opaque-test-id",
                        "kind": "function",
                        "name": "Fixture.test",
                        "sourceLocation": {"file": "Tests/Fixture.swift", "line": 1},
                    },
                },
                event_record("runStarted", 1.0),
                event_record("runEnded", 2.0),
            ]
        )
        status, _, error = self.run_report(enforce_budget=True)
        self.assertEqual(status, 1)
        self.assertIn("sourceLocation.fileID must be a string", error)

    def test_unknown_record_and_event_kinds_are_ignored(self) -> None:
        records = [
            {"version": 0, "kind": "future-record", "payload": {"anything": True}},
            event_record("futureEvent", "not a timestamp"),
            event_record("runEnded", 5.0),
            event_record("runStarted", 1.0),
        ]
        self.write_records(records)
        status, output, error = self.run_report(enforce_budget=True)
        self.assertEqual(status, 0, error)
        self.assertIn("Whole-invocation envelope: 4.000s", output)

    def test_rejects_empty_missing_malformed_and_unsupported_streams(self) -> None:
        self.path.write_text("", encoding="utf-8")
        status, _, error = self.run_report(enforce_budget=True)
        self.assertEqual(status, 1)
        self.assertIn("is empty", error)

        self.path.write_text("{\"version\":0,\"kind\":\"event\"", encoding="utf-8")
        status, _, error = self.run_report(enforce_budget=True)
        self.assertEqual(status, 1)
        self.assertIn("malformed JSON", error)

        self.path.write_text(
            json.dumps({"version": 1, "kind": "event", "payload": {}}), encoding="utf-8"
        )
        status, _, error = self.run_report(enforce_budget=True)
        self.assertEqual(status, 1)
        self.assertIn("unsupported", error)

        self.path.unlink()
        status, _, error = self.run_report(enforce_budget=True)
        self.assertEqual(status, 1)
        self.assertIn("cannot read event file", error)

    def test_rejects_missing_start_nonfinite_and_negative_intervals(self) -> None:
        self.write_records([event_record("runEnded", 2.0)])
        status, _, error = self.run_report(enforce_budget=True)
        self.assertEqual(status, 1)
        self.assertIn("unmatched runEnded", error)

        self.path.write_text(
            '{"version":0,"kind":"event","payload":{"kind":"runStarted",'
            '"instant":{"absolute":1e999},"messages":[]}}\n',
            encoding="utf-8",
        )
        status, _, error = self.run_report(enforce_budget=True)
        self.assertEqual(status, 1)
        self.assertIn("finite numeric timestamp", error)

        self.write_records([event_record("runStarted", 5.0), event_record("runEnded", 4.0)])
        status, _, error = self.run_report(enforce_budget=True)
        self.assertEqual(status, 1)
        self.assertIn("negative suite interval", error)

        self.write_records(
            [
                test_record("negative"),
                event_record("runStarted", 1.0),
                event_record("testStarted", 4.0, test_id="negative"),
                event_record("testEnded", 3.0, test_id="negative"),
                event_record("runEnded", 5.0),
            ]
        )
        status, _, error = self.run_report(enforce_budget=True)
        self.assertEqual(status, 1)
        self.assertIn("precedes testStarted", error)

    def test_rejects_duplicate_or_nested_run_lifecycle_and_duplicate_test_events(self) -> None:
        cases = (
            (
                [event_record("runStarted", 1.0), event_record("runStarted", 1.1)],
                "overlapping or nested runStarted",
            ),
            (
                [event_record("runStarted", 1.0), event_record("runStarted", 1.0)],
                "duplicate runStarted",
            ),
            (
                [event_record("runStarted", 1.0), event_record("runEnded", 2.0),
                 event_record("runEnded", 2.1)],
                "unmatched runEnded",
            ),
            (
                [test_record("duplicate"), event_record("runStarted", 1.0),
                 event_record("testStarted", 1.1, test_id="duplicate"),
                 event_record("testStarted", 1.2, test_id="duplicate"),
                 event_record("runEnded", 2.0)],
                "duplicate testStarted",
            ),
            (
                [test_record("duplicate"), event_record("runStarted", 1.0),
                 event_record("testStarted", 1.1, test_id="duplicate"),
                 event_record("testEnded", 1.2, test_id="duplicate"),
                 event_record("testEnded", 1.3, test_id="duplicate"),
                 event_record("runEnded", 2.0)],
                "duplicate testEnded",
            ),
        )
        for records, expected in cases:
            with self.subTest(expected=expected):
                self.write_records(records)
                status, _, error = self.run_report(enforce_budget=True)
                self.assertEqual(status, 1)
                self.assertIn(expected, error)

    def test_cli_reports_incomplete_runs(self) -> None:
        self.write_records([event_record("runStarted", 10.0)])
        from report_test_events import main

        stdout = io.StringIO()
        stderr = io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            status = main([str(self.path)])
        self.assertEqual(status, 1)
        self.assertIn("INCOMPLETE", stdout.getvalue())
        self.assertEqual(stderr.getvalue(), "")

    def test_cli_filtered_flag_disables_budget_enforcement(self) -> None:
        self.write_records(
            [
                event_record("runStarted", 0.0),
                event_record("runEnded", SUITE_BUDGET_SECONDS + 1.0),
            ]
        )
        from report_test_events import main

        stdout = io.StringIO()
        stderr = io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            status = main([str(self.path), "--filtered"])
        self.assertEqual(status, 0, stderr.getvalue())
        self.assertIn("Budget: not applied (filtered run)", stdout.getvalue())
        self.assertIn("Run status: PASS", stdout.getvalue())
        self.assertEqual(stderr.getvalue(), "")


if __name__ == "__main__":
    unittest.main()
