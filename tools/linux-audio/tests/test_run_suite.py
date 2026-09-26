from pathlib import Path

import run_suite
from run_suite import CheckResult, Status


def test_optional_command_check_skips_before_running_when_module_missing(
    monkeypatch,
    tmp_path,
):
    calls = []
    monkeypatch.setattr(
        run_suite.importlib.util,
        "find_spec",
        lambda _: None,
    )
    monkeypatch.setattr(
        run_suite,
        "run_command",
        lambda *args, **kwargs: calls.append((args, kwargs)),
    )

    result = run_suite.optional_command_check(
        "qwen",
        ["python", "qwen3_asr.py"],
        tmp_path,
        modules=("qwen_asr",),
    )

    assert result.status is Status.SKIPPED_MISSING_DEPENDENCY
    assert calls == []


def test_optional_command_check_reports_command_failure(
    monkeypatch,
    tmp_path,
):
    monkeypatch.setattr(
        run_suite.importlib.util,
        "find_spec",
        lambda _: object(),
    )
    monkeypatch.setattr(
        run_suite,
        "run_command",
        lambda name, command, cwd:
            CheckResult(name, Status.FAIL, "boom"),
    )

    result = run_suite.optional_command_check(
        "qwen",
        ["python", "qwen3_asr.py"],
        tmp_path,
        modules=("qwen_asr",),
    )

    assert result.status is Status.FAIL
    assert result.detail == "boom"


def test_full_model_checks_keep_qwen_and_nemotron_separate(
    monkeypatch,
    tmp_path,
):
    audio = tmp_path / "fixture.wav"
    audio.write_bytes(b"RIFF")
    seen = []

    def fake_optional(name, command, cwd, **kwargs):
        seen.append((name, command, kwargs))
        return CheckResult(name, Status.PASS)

    monkeypatch.setattr(
        run_suite,
        "optional_command_check",
        fake_optional,
    )

    checks = run_suite.full_model_checks(
        here=tmp_path,
        audio_path=audio,
        work_root=tmp_path / "work",
        device="cuda:0",
        match_threshold=0.82,
        ambiguity_margin=0.04,
        min_clean_speech_ms=750,
    )

    assert [item.name for item in checks] == [
        "qwen3-asr-runner",
        "nemotron3-runner",
    ]
    assert "-m asr.qwen3_asr" in " ".join(seen[0][1])
    assert "-m diarization.nemotron3" in " ".join(seen[1][1])
    assert "--match-threshold" in seen[1][1]
    assert "0.82" in seen[1][1]


def test_full_model_checks_skip_nemotron_without_calibrated_thresholds(
    monkeypatch,
    tmp_path,
):
    audio = tmp_path / "fixture.wav"
    audio.write_bytes(b"RIFF")
    monkeypatch.setattr(
        run_suite,
        "optional_command_check",
        lambda name, command, cwd, **kwargs:
            CheckResult(name, Status.PASS),
    )

    checks = run_suite.full_model_checks(
        here=tmp_path,
        audio_path=audio,
        work_root=tmp_path / "work",
        device="cuda:0",
        match_threshold=None,
        ambiguity_margin=None,
        min_clean_speech_ms=750,
    )

    assert checks[0].status is Status.PASS
    assert (
        checks[1].status
        is Status.SKIPPED_MISSING_DEPENDENCY
    )
    assert "calibrated" in (checks[1].detail or "")


def test_main_full_appends_real_model_runner_checks(
    monkeypatch,
    tmp_path,
):
    audio = tmp_path / "fixture.wav"
    audio.write_bytes(b"RIFF")
    captured = []

    monkeypatch.setattr(
        run_suite,
        "run_command",
        lambda name, command, cwd:
            CheckResult(name, Status.PASS),
    )
    monkeypatch.setattr(
        run_suite,
        "optional_executable_check",
        lambda name, executable:
            CheckResult(name, Status.PASS),
    )
    monkeypatch.setattr(
        run_suite,
        "optional_import_check",
        lambda name, module:
            CheckResult(name, Status.PASS),
    )

    def fake_full_model_checks(**kwargs):
        captured.append(kwargs)
        return [
            CheckResult("qwen3-asr-runner", Status.PASS),
            CheckResult("nemotron3-runner", Status.PASS),
        ]

    monkeypatch.setattr(
        run_suite,
        "full_model_checks",
        fake_full_model_checks,
    )

    result = run_suite.main([
        "--full",
        "--full-audio",
        str(audio),
        "--work-root",
        str(tmp_path / "work"),
        "--device",
        "cuda:1",
        "--speaker-match-threshold",
        "0.82",
        "--speaker-ambiguity-margin",
        "0.04",
        "--min-clean-speech-ms",
        "750",
    ])

    assert result == 0
    assert captured[0]["audio_path"] == audio
    assert captured[0]["device"] == "cuda:1"
    assert captured[0]["match_threshold"] == 0.82
    assert captured[0]["ambiguity_margin"] == 0.04
    assert captured[0]["min_clean_speech_ms"] == 750


def test_summary_is_pass_only_when_all_pass():
    summary = run_suite.summarize([
        CheckResult("a", Status.PASS),
        CheckResult("b", Status.PASS),
    ])
    assert summary.overall == Status.PASS
    assert summary.exit_code == 0


def test_summary_fails_when_any_check_fails():
    summary = run_suite.summarize([
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
    summary = run_suite.summarize([
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


def test_executable_check_marks_missing_tool_as_skip(
    monkeypatch,
):
    monkeypatch.setattr(
        run_suite.shutil,
        "which",
        lambda _: None,
    )
    result = run_suite.optional_executable_check(
        "ffmpeg",
        "ffmpeg",
    )
    assert (
        result.status
        is Status.SKIPPED_MISSING_DEPENDENCY
    )
