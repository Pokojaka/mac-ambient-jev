from run_suite import CheckResult, Status, summarize


def test_summary_is_pass_only_when_all_pass():
    summary = summarize([
        CheckResult("a", Status.PASS),
        CheckResult("b", Status.PASS),
    ])
    assert summary.overall == Status.PASS
    assert summary.exit_code == 0


def test_summary_fails_when_any_check_fails():
    summary = summarize([
        CheckResult("a", Status.PASS),
        CheckResult("b", Status.FAIL, "broken"),
        CheckResult(
            "c",
            Status.SKIPPED_MISSING_DEPENDENCY,
        ),
    ])
    assert summary.overall == Status.FAIL
    assert summary.exit_code == 1


def test_missing_dependency_is_not_reported_as_pass():
    summary = summarize([
        CheckResult("core", Status.PASS),
        CheckResult(
            "nemotron",
            Status.SKIPPED_MISSING_DEPENDENCY,
            "nemo missing",
        ),
    ])
    assert (
        summary.overall
        == Status.SKIPPED_MISSING_DEPENDENCY
    )
    assert summary.exit_code == 2
