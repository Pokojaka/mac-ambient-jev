import json
from pathlib import Path

import pytest

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


def test_asr_and_diarization_checks_keep_qwen_and_nemotron_separate(
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

    reference = tmp_path / "speaker-reference.json"
    reference.write_text("[]")
    checks = run_suite.asr_model_checks(
        here=tmp_path,
        audio_path=audio,
        work_root=tmp_path / "work",
        device="cpu",
    ) + run_suite.diarization_model_checks(
        here=tmp_path,
        audio_path=audio,
        speaker_reference=reference,
        work_root=tmp_path / "work",
        device="cpu",
        match_threshold=0.82,
        ambiguity_margin=0.04,
        min_clean_speech_ms=750,
    )

    assert [item.name for item in checks] == [
        "qwen3-asr-runner",
        "asr-evaluator",
        "asr-baseline-record",
        "nemotron3-runner",
        "diarization-evaluator",
        "diarization-baseline-record",
    ]
    assert "-m asr.qwen3_asr" in " ".join(seen[0][1])
    assert "MacAmbientJevEvaluateASR" in seen[1][1]
    assert "-m diarization.nemotron3" in " ".join(seen[2][1])
    assert "--match-threshold" in seen[2][1]
    assert "0.82" in seen[2][1]
    assert "MacAmbientJevEvaluateDiarization" in seen[3][1]
    assert str(reference) in seen[3][1]
    assert str(
        tmp_path / "work" / "nemotron3.json"
    ) in seen[3][1]


def test_diarization_checks_skip_nemotron_without_calibrated_thresholds(
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

    reference = tmp_path / "speaker-reference.json"
    reference.write_text("[]")
    checks = run_suite.diarization_model_checks(
        here=tmp_path,
        audio_path=audio,
        speaker_reference=reference,
        work_root=tmp_path / "work",
        device="cpu",
        match_threshold=None,
        ambiguity_margin=None,
        min_clean_speech_ms=750,
    )

    assert checks[0].name == "nemotron3-runner"
    assert (
        checks[0].status
        is Status.SKIPPED_MISSING_DEPENDENCY
    )
    assert "calibrated" in (checks[0].detail or "")


def stub_model_suite(monkeypatch):
    captured = {}
    for name in (
        "run_command",
        "optional_executable_check",
        "optional_import_check",
    ):
        monkeypatch.setattr(
            run_suite,
            name,
            lambda name, *args: CheckResult(name, Status.PASS),
        )
    monkeypatch.setattr(
        run_suite,
        "optional_command_check",
        lambda name, command, cwd, **kwargs:
            CheckResult(name, Status.PASS),
    )
    monkeypatch.setattr(
        run_suite,
        "asr_baseline_check",
        lambda **kwargs:
            CheckResult("asr-baseline-record", Status.PASS),
    )
    monkeypatch.setattr(
        run_suite,
        "diarization_baseline_check",
        lambda **kwargs:
            CheckResult("diarization-baseline-record", Status.PASS),
    )
    for name in ("asr_model_checks", "diarization_model_checks"):
        real = getattr(run_suite, name)

        def spy(real=real, name=name, **kwargs):
            captured[name] = kwargs
            return real(**kwargs)

        monkeypatch.setattr(run_suite, name, spy)
    return captured


def check_names(capsys) -> list[str]:
    payload = json.loads(capsys.readouterr().out)
    return [check["name"] for check in payload["checks"]]


def test_main_full_without_diarization_omits_nemotron_and_passes(
    monkeypatch,
    tmp_path,
    capsys,
):
    captured = stub_model_suite(monkeypatch)

    result = run_suite.main([
        "--full",
        "--full-audio",
        str(tmp_path / "fixture.wav"),
        "--work-root",
        str(tmp_path / "work"),
    ])

    names = check_names(capsys)
    assert result == 0
    assert "qwen3-asr-runner" in names
    assert "asr-baseline-record" in names
    assert not any(
        "nemotron" in name or "diarization" in name
        for name in names
    )
    assert "diarization_model_checks" not in captured
    assert captured["asr_model_checks"]["device"] == "cpu"


def test_main_full_with_diarization_appends_nemotron_checks(
    monkeypatch,
    tmp_path,
    capsys,
):
    captured = stub_model_suite(monkeypatch)
    audio = tmp_path / "fixture.wav"

    result = run_suite.main([
        "--full",
        "--with-diarization",
        "--full-audio",
        str(audio),
        "--full-speaker-reference",
        str(tmp_path / "speaker-reference.json"),
        "--full-asr-reference",
        str(tmp_path / "reference-content.txt"),
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

    names = check_names(capsys)
    assert result == 0
    assert names[-3:] == [
        "nemotron3-runner",
        "diarization-evaluator",
        "diarization-baseline-record",
    ]
    asr = captured["asr_model_checks"]
    diarization = captured["diarization_model_checks"]
    assert asr["audio_path"] == audio
    assert asr["asr_reference"] == (
        tmp_path / "reference-content.txt"
    )
    assert asr["device"] == "cuda:1"
    assert diarization["speaker_reference"] == (
        tmp_path / "speaker-reference.json"
    )
    assert diarization["device"] == "cuda:1"
    assert diarization["match_threshold"] == 0.82
    assert diarization["ambiguity_margin"] == 0.04
    assert diarization["min_clean_speech_ms"] == 750


def test_main_with_diarization_missing_deps_is_not_pass(
    monkeypatch,
    tmp_path,
    capsys,
):
    stub_model_suite(monkeypatch)

    result = run_suite.main([
        "--full",
        "--with-diarization",
        "--full-audio",
        str(tmp_path / "fixture.wav"),
        "--work-root",
        str(tmp_path / "work"),
    ])

    payload = json.loads(capsys.readouterr().out)
    assert result == 2
    assert payload["overall"] == "SKIPPED_MISSING_DEPENDENCY"


@pytest.mark.parametrize(
    "argv",
    [
        ["--smoke", "--with-diarization"],
        ["--full", "--speaker-match-threshold", "0.82"],
        ["--full", "--full-speaker-reference", "ref.json"],
    ],
)
def test_main_rejects_diarization_options_without_opt_in(
    monkeypatch,
    tmp_path,
    argv,
):
    stub_model_suite(monkeypatch)

    with pytest.raises(SystemExit) as exit_info:
        run_suite.main(argv)

    assert exit_info.value.code == 2


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


def test_diarization_checks_remove_stale_nemotron_artifact(
    monkeypatch,
    tmp_path,
):
    audio = tmp_path / "fixture.wav"
    audio.write_bytes(b"RIFF")
    reference = tmp_path / "speaker-reference.json"
    reference.write_text("[]")
    work = tmp_path / "work"
    work.mkdir()
    stale = work / "nemotron3.json"
    stale.write_text('{"stale":true}')

    def fake_optional(name, command, cwd, **kwargs):
        if name == "diarization-evaluator":
            assert not stale.exists()
            return CheckResult(
                name,
                Status.SKIPPED_MISSING_DEPENDENCY,
                "artifact missing",
            )
        return CheckResult(name, Status.PASS)

    monkeypatch.setattr(
        run_suite,
        "optional_command_check",
        fake_optional,
    )

    checks = run_suite.diarization_model_checks(
        here=tmp_path,
        audio_path=audio,
        speaker_reference=reference,
        work_root=work,
        device="cpu",
        match_threshold=None,
        ambiguity_margin=None,
        min_clean_speech_ms=None,
    )

    assert not stale.exists()
    assert checks[-2].name == "diarization-evaluator"
    assert (
        checks[-2].status
        is Status.SKIPPED_MISSING_DEPENDENCY
    )
    assert checks[-1].name == "diarization-baseline-record"
    assert (
        checks[-1].status
        is Status.SKIPPED_MISSING_DEPENDENCY
    )


def test_optional_command_check_fails_when_expected_output_missing(
    monkeypatch,
    tmp_path,
):
    monkeypatch.setattr(
        run_suite,
        "run_command",
        lambda name, command, cwd:
            CheckResult(name, Status.PASS),
    )

    expected = tmp_path / "missing.json"
    result = run_suite.optional_command_check(
        "evaluator",
        ["tool"],
        tmp_path,
        outputs=(expected,),
    )

    assert result.status is Status.FAIL
    assert "Expected output" in (result.detail or "")


def test_optional_command_check_accepts_expected_output(
    monkeypatch,
    tmp_path,
):
    expected = tmp_path / "result.json"

    def fake_run(name, command, cwd):
        expected.write_text("{}")
        return CheckResult(name, Status.PASS)

    monkeypatch.setattr(
        run_suite,
        "run_command",
        fake_run,
    )

    result = run_suite.optional_command_check(
        "evaluator",
        ["tool"],
        tmp_path,
        outputs=(expected,),
    )

    assert result.status is Status.PASS


def test_diarization_checks_write_evaluation_artifact(
    monkeypatch,
    tmp_path,
):
    audio = tmp_path / "fixture.wav"
    audio.write_bytes(b"RIFF")
    reference = tmp_path / "speaker-reference.json"
    reference.write_text("[]")
    work = tmp_path / "work"
    work.mkdir()
    stale_evaluation = work / "diarization-evaluation.json"
    stale_evaluation.write_text('{"stale":true}')
    seen = []

    def fake_optional(name, command, cwd, **kwargs):
        seen.append((name, command, kwargs))
        if name == "nemotron3-runner":
            (work / "nemotron3.json").write_text("{}")
        if name == "diarization-evaluator":
            assert not stale_evaluation.exists()
            stale_evaluation.write_text("{}")
        return CheckResult(name, Status.PASS)

    monkeypatch.setattr(
        run_suite,
        "optional_command_check",
        fake_optional,
    )
    monkeypatch.setattr(
        run_suite,
        "diarization_baseline_check",
        lambda **kwargs:
            CheckResult("diarization-baseline-record", Status.PASS),
    )

    checks = run_suite.diarization_model_checks(
        here=tmp_path,
        audio_path=audio,
        speaker_reference=reference,
        work_root=work,
        device="cpu",
        match_threshold=0.82,
        ambiguity_margin=0.04,
        min_clean_speech_ms=750,
    )

    evaluator = next(
        item for item in seen
        if item[0] == "diarization-evaluator"
    )
    assert "--output" in evaluator[1]
    assert str(stale_evaluation) in evaluator[1]
    assert evaluator[2]["outputs"] == (stale_evaluation,)
    assert checks[-1].status is Status.PASS


def test_diarization_baseline_check_writes_current_record(
    monkeypatch,
    tmp_path,
):
    audio = tmp_path / "audio.wav"
    reference = tmp_path / "speaker-reference.json"
    artifact = tmp_path / "nemotron3.json"
    evaluation = tmp_path / "diarization-evaluation.json"
    for path in (audio, reference, artifact, evaluation):
        path.write_text("x")
    output = tmp_path / "nemotron3-current.json"

    class Record:
        def write(self, path):
            path.write_text('{"ok":true}')

    captured = {}

    def fake_build(**kwargs):
        captured.update(kwargs)
        return Record()

    monkeypatch.setattr(
        run_suite,
        "build_diarization_baseline_record",
        fake_build,
    )

    result = run_suite.diarization_baseline_check(
        audio_path=audio,
        speaker_reference=reference,
        artifact_path=artifact,
        evaluation_path=evaluation,
        output_path=output,
    )

    assert result.status is Status.PASS
    assert output.is_file()
    assert captured["artifact_path"] == artifact
    assert captured["evaluation_path"] == evaluation


def test_diarization_baseline_check_skips_missing_inputs(tmp_path):
    result = run_suite.diarization_baseline_check(
        audio_path=tmp_path / "audio.wav",
        speaker_reference=tmp_path / "reference.json",
        artifact_path=tmp_path / "artifact.json",
        evaluation_path=tmp_path / "evaluation.json",
        output_path=tmp_path / "current.json",
    )

    assert (
        result.status
        is Status.SKIPPED_MISSING_DEPENDENCY
    )


def test_asr_baseline_check_writes_current_record(
    monkeypatch,
    tmp_path,
):
    audio = tmp_path / "audio.wav"
    reference = tmp_path / "reference.txt"
    artifact = tmp_path / "qwen3-asr.json"
    evaluation = tmp_path / "asr-evaluation.json"
    for path in (audio, reference, artifact, evaluation):
        path.write_text("x")
    output = tmp_path / "qwen3-asr-current.json"

    class Record:
        def write(self, path):
            path.write_text('{"ok":true}')

    captured = {}

    def fake_build(**kwargs):
        captured.update(kwargs)
        return Record()

    monkeypatch.setattr(
        run_suite,
        "build_asr_baseline_record",
        fake_build,
    )

    result = run_suite.asr_baseline_check(
        audio_path=audio,
        reference_path=reference,
        artifact_path=artifact,
        evaluation_path=evaluation,
        output_path=output,
    )

    assert result.status is Status.PASS
    assert output.is_file()
    assert captured["artifact_path"] == artifact
    assert captured["evaluation_path"] == evaluation
    assert captured["reference_path"] == reference


def test_asr_checks_run_evaluator_with_explicit_reference(
    monkeypatch,
    tmp_path,
):
    audio = tmp_path / "fixture.wav"
    audio.write_bytes(b"RIFF")
    asr_reference = tmp_path / "reference-content.txt"
    asr_reference.write_text("参照文")
    seen = []

    def fake_optional(name, command, cwd, **kwargs):
        seen.append((name, command, kwargs))
        work = tmp_path / "work"
        if name == "qwen3-asr-runner":
            work.mkdir(exist_ok=True)
            (work / "qwen3-asr.json").write_text("{}")
        if name == "asr-evaluator":
            (work / "asr-evaluation.json").write_text("{}")
        return CheckResult(name, Status.PASS)

    monkeypatch.setattr(
        run_suite,
        "optional_command_check",
        fake_optional,
    )
    monkeypatch.setattr(
        run_suite,
        "asr_baseline_check",
        lambda **kwargs:
            CheckResult("asr-baseline-record", Status.PASS),
    )

    checks = run_suite.asr_model_checks(
        here=tmp_path,
        audio_path=audio,
        work_root=tmp_path / "work",
        device="cpu",
        asr_reference=asr_reference,
    )

    asr = next(item for item in seen if item[0] == "asr-evaluator")
    assert "MacAmbientJevEvaluateASR" in asr[1]
    assert str(asr_reference) in asr[1]
    assert any(
        item.name == "asr-baseline-record"
        and item.status is Status.PASS
        for item in checks
    )
