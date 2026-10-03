import json

import pytest

import run_suite
from common.artifact import build_asr_artifact, build_engine, build_runtime
from common.baseline import load_baseline
from common.runtime_metrics import RuntimeMeasurement
from run_suite import CheckResult, Status


def test_optional_command_check_skips_before_running_when_module_missing(
    monkeypatch,
    tmp_path,
):
    calls = []
    monkeypatch.setattr(run_suite.importlib.util, "find_spec", lambda _: None)
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
        lambda name, command, cwd: CheckResult(name, Status.FAIL, "boom"),
    )

    result = run_suite.optional_command_check(
        "qwen",
        ["python", "qwen3_asr.py"],
        tmp_path,
        modules=("qwen_asr",),
    )

    assert result.status is Status.FAIL
    assert result.detail == "boom"


def test_optional_command_check_fails_when_expected_output_missing(
    monkeypatch,
    tmp_path,
):
    monkeypatch.setattr(
        run_suite,
        "run_command",
        lambda name, command, cwd: CheckResult(name, Status.PASS),
    )

    result = run_suite.optional_command_check(
        "evaluator",
        ["tool"],
        tmp_path,
        outputs=(tmp_path / "missing.json",),
    )

    assert result.status is Status.FAIL
    assert "Expected output" in (result.detail or "")


def record_optional_commands(monkeypatch, work):
    seen = []

    def fake_optional(name, command, cwd, **kwargs):
        seen.append((name, command, kwargs))
        for output in kwargs.get("outputs", ()):
            assert not output.exists(), "stale output must be removed"
        return CheckResult(name, Status.PASS)

    monkeypatch.setattr(run_suite, "optional_command_check", fake_optional)
    return seen


def test_asr_checks_score_verbatim_first_and_content_as_supplement(
    monkeypatch,
    tmp_path,
):
    audio = tmp_path / "fixture.wav"
    verbatim = tmp_path / "reference-verbatim.txt"
    content = tmp_path / "reference-content.txt"
    work = tmp_path / "work"
    work.mkdir()
    for stale in (
        "qwen3-asr.json",
        "asr-evaluation-verbatim.json",
        "asr-evaluation-content.json",
    ):
        (work / stale).write_text("{}")
    seen = record_optional_commands(monkeypatch, work)

    checks = run_suite.asr_model_checks(
        here=tmp_path / "tools" / "linux-audio",
        audio_path=audio,
        asr_references={"content": content, "verbatim": verbatim},
        work_root=work,
        device="cpu",
    )

    assert [check.name for check in checks] == [
        "qwen3-asr-runner",
        "asr-evaluator-verbatim",
        "asr-baseline-verbatim",
        "asr-evaluator-content",
        "asr-baseline-content",
    ]
    assert not (work / "qwen3-asr.json").exists()
    assert str(verbatim) in seen[1][1]
    assert str(content) in seen[2][1]
    assert checks[2].status is Status.SKIPPED_MISSING_DEPENDENCY


def test_asr_checks_require_a_verbatim_reference(tmp_path):
    with pytest.raises(ValueError, match="verbatim"):
        run_suite.asr_model_checks(
            here=tmp_path,
            audio_path=tmp_path / "fixture.wav",
            asr_references={"content": tmp_path / "content.txt"},
            work_root=tmp_path / "work",
            device="cpu",
        )


def test_diarization_checks_pass_calibration_and_remove_stale_outputs(
    monkeypatch,
    tmp_path,
):
    work = tmp_path / "work"
    work.mkdir()
    (work / "nemotron3.json").write_text('{"stale":true}')
    (work / "diarization-evaluation.json").write_text('{"stale":true}')
    seen = record_optional_commands(monkeypatch, work)
    reference = tmp_path / "speaker-reference.json"

    checks = run_suite.diarization_model_checks(
        here=tmp_path / "tools" / "linux-audio",
        audio_path=tmp_path / "fixture.wav",
        speaker_reference=reference,
        work_root=work,
        device="cuda:1",
        profile="low-1.04s",
        match_threshold=0.82,
        ambiguity_margin=0.04,
        min_clean_speech_ms=750,
    )

    assert [check.name for check in checks] == [
        "nemotron3-runner",
        "diarization-evaluator",
        "diarization-baseline-record",
    ]
    assert not (work / "nemotron3.json").exists()
    runner = seen[0][1]
    for flag, value in (
        ("--device", "cuda:1"),
        ("--profile", "low-1.04s"),
        ("--match-threshold", "0.82"),
        ("--ambiguity-margin", "0.04"),
        ("--min-clean-speech-ms", "750"),
    ):
        assert runner[runner.index(flag) + 1] == value
    assert str(reference) in seen[1][1]
    assert checks[2].status is Status.SKIPPED_MISSING_DEPENDENCY


def write_asr_inputs(tmp_path):
    audio = tmp_path / "audio.wav"
    audio.write_bytes(b"audio")
    reference = tmp_path / "reference.txt"
    reference.write_text("参照文\n", encoding="utf-8")
    artifact = tmp_path / "qwen3-asr.json"
    artifact.write_text(json.dumps(build_asr_artifact(
        engine=build_engine(
            name="qwen3-asr",
            model="Qwen/Qwen3-ASR-1.7B",
            revision="rev",
            backend="transformers",
            device="cpu",
            package_versions={"qwen-asr": "0.0.6"},
            inference_config={"language": "Japanese"},
        ),
        runtime=build_runtime(
            device="cpu",
            audio_seconds=1.0,
            measurement=RuntimeMeasurement(5.0, 0.5, None, None),
        ),
        text="参照文",
        language="Japanese",
    )))
    evaluation = tmp_path / "asr-evaluation.json"
    rate = {
        "rate": 0.0,
        "substitutions": 0,
        "deletions": 0,
        "insertions": 0,
        "reference_characters": 3,
        "hypothesis_characters": 3,
    }
    evaluation.write_text(json.dumps({
        "raw": rate,
        "normalized": rate,
        "normalizer_version": "1",
    }))
    return audio, reference, artifact, evaluation


def test_asr_baseline_check_writes_a_loadable_record(tmp_path):
    audio, reference, artifact, evaluation = write_asr_inputs(tmp_path)
    output = tmp_path / "current.json"

    result = run_suite.asr_baseline_check(
        name="asr-baseline-verbatim",
        audio_path=audio,
        reference_path=reference,
        reference_kind="verbatim",
        artifact_path=artifact,
        evaluation_path=evaluation,
        output_path=output,
    )

    assert result.status is Status.PASS
    assert load_baseline(output).conditions["reference_kind"] == "verbatim"


def test_asr_baseline_check_fails_on_invalid_artifact(tmp_path):
    audio, reference, artifact, evaluation = write_asr_inputs(tmp_path)
    artifact.write_text('{"schema_version": 1}')
    output = tmp_path / "current.json"
    output.write_text("stale")

    result = run_suite.asr_baseline_check(
        name="asr-baseline-verbatim",
        audio_path=audio,
        reference_path=reference,
        reference_kind="verbatim",
        artifact_path=artifact,
        evaluation_path=evaluation,
        output_path=output,
    )

    assert result.status is Status.FAIL
    assert "schema_version" in (result.detail or "")
    assert not output.exists()


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
    for name in ("asr_model_checks", "diarization_model_checks"):
        def spy(name=name, **kwargs):
            captured[name] = kwargs
            return [CheckResult(name, Status.PASS)]

        monkeypatch.setattr(run_suite, name, spy)
    return captured


FULL = [
    "--full",
    "--full-audio", "fixture.wav",
    "--full-asr-reference-verbatim", "reference-verbatim.txt",
    "--work-root", "work",
    "--device", "cpu",
]
DIARIZATION = [
    "--with-diarization",
    "--full-speaker-reference", "speaker-reference.json",
    "--diarization-profile", "offline-30.4s",
    "--speaker-match-threshold", "0.82",
    "--speaker-ambiguity-margin", "0.04",
    "--min-clean-speech-ms", "750",
]


def test_main_full_passes_references_and_omits_diarization(
    monkeypatch,
    capsys,
):
    captured = stub_model_suite(monkeypatch)

    result = run_suite.main(
        FULL + ["--full-asr-reference-content", "reference-content.txt"]
    )

    assert result == 0
    assert "diarization_model_checks" not in captured
    references = captured["asr_model_checks"]["asr_references"]
    assert {kind: path.name for kind, path in references.items()} == {
        "verbatim": "reference-verbatim.txt",
        "content": "reference-content.txt",
    }
    json.loads(capsys.readouterr().out)


def test_main_full_with_diarization_passes_calibration(monkeypatch):
    captured = stub_model_suite(monkeypatch)

    assert run_suite.main(FULL + DIARIZATION) == 0

    diarization = captured["diarization_model_checks"]
    assert diarization["speaker_reference"].name == "speaker-reference.json"
    assert diarization["profile"] == "offline-30.4s"
    assert diarization["match_threshold"] == 0.82
    assert diarization["ambiguity_margin"] == 0.04
    assert diarization["min_clean_speech_ms"] == 750


@pytest.mark.parametrize(
    "argv",
    [
        ["--smoke", "--with-diarization"],
        ["--smoke", "--device", "cpu"],
        ["--full"],
        FULL[:-2],
        FULL + DIARIZATION[:-2],
        FULL + ["--speaker-match-threshold", "0.82"],
    ],
)
def test_main_rejects_incomplete_or_misplaced_options(monkeypatch, argv):
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
        CheckResult("c", Status.SKIPPED_MISSING_DEPENDENCY),
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
    assert summary.overall == Status.SKIPPED_MISSING_DEPENDENCY
    assert summary.exit_code == 2


def test_executable_check_marks_missing_tool_as_skip(monkeypatch):
    monkeypatch.setattr(run_suite.shutil, "which", lambda _: None)
    result = run_suite.optional_executable_check("ffmpeg", "ffmpeg")
    assert result.status is Status.SKIPPED_MISSING_DEPENDENCY
