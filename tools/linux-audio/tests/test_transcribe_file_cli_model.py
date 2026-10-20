from __future__ import annotations

import json
import os
from pathlib import Path
import re
import subprocess
import sys

import pytest

from common.artifact import validate_asr_artifact


@pytest.mark.skipif(
    sys.platform == "darwin",
    reason="The portable release CLI is tested on Linux and Windows, not macOS.",
)
@pytest.mark.skipif(
    sys.platform not in {"linux", "win32"},
    reason="The portable release CLI is supported by this test only on Linux and Windows.",
)
@pytest.mark.skipif(
    os.environ.get("RUN_MODEL_TESTS") != "1",
    reason="Set RUN_MODEL_TESTS=1 to run the end-to-end model CLI test.",
)
def test_transcribe_file_cli_model(tmp_path: Path) -> None:
    root = Path(__file__).resolve().parents[3]

    def required_environment_value(name: str) -> str:
        value = os.environ.get(name)
        if value is None or value == "":
            pytest.fail(f"{name} is required when RUN_MODEL_TESTS=1")
        return value

    model_directory_value = required_environment_value(
        "QWEN3_ASR_ONNX_MODEL_DIRECTORY"
    )
    model_directory = Path(model_directory_value)
    if not model_directory.is_absolute():
        pytest.fail("QWEN3_ASR_ONNX_MODEL_DIRECTORY must be an absolute path")
    if not model_directory.is_dir() or not os.access(model_directory, os.R_OK):
        pytest.fail(
            "QWEN3_ASR_ONNX_MODEL_DIRECTORY must name an existing readable directory"
        )

    model_size = required_environment_value("QWEN3_ASR_ONNX_MODEL_SIZE")
    if model_size not in {"0.6b", "1.7b"}:
        pytest.fail("QWEN3_ASR_ONNX_MODEL_SIZE must be exactly 0.6b or 1.7b")

    silero_model = Path(
        required_environment_value("MAC_AMBIENT_JEV_SILERO_MODEL")
    )
    if not silero_model.is_file() or not os.access(silero_model, os.R_OK):
        pytest.fail(
            "MAC_AMBIENT_JEV_SILERO_MODEL must name an existing readable regular file"
        )
    silero_model = silero_model.resolve()

    package_path = Path("app/MacAmbientJev")
    app_directory = root / package_path
    for product in ("MacAmbientJevTranscribeFile", "MacAmbientJevEvaluateASR"):
        subprocess.run(
            [
                "swift",
                "build",
                "--package-path",
                str(package_path),
                "-c",
                "release",
                "--product",
                product,
            ],
            cwd=root,
            check=True,
        )

    bin_path_result = subprocess.run(
        [
            "swift",
            "build",
            "--package-path",
            str(app_directory),
            "-c",
            "release",
            "--show-bin-path",
        ],
        cwd=root,
        capture_output=True,
        text=True,
        check=True,
    )
    bin_path_text = bin_path_result.stdout.strip()
    assert bin_path_text, "swift build --show-bin-path returned an empty path"
    bin_path = Path(bin_path_text)
    if not bin_path.is_absolute():
        bin_path = root / bin_path
    executable_suffix = ".exe" if sys.platform == "win32" else ""
    transcribe_binary = bin_path / f"MacAmbientJevTranscribeFile{executable_suffix}"
    evaluate_binary = bin_path / f"MacAmbientJevEvaluateASR{executable_suffix}"
    assert transcribe_binary.is_file(), f"Missing release CLI: {transcribe_binary}"
    assert evaluate_binary.is_file(), f"Missing release evaluator: {evaluate_binary}"

    fixture = (
        app_directory
        / "Tests/MacAmbientJevPortableRuntimeTests/Resources/qwen3_asr_voicevox_long.wav"
    )
    assert fixture.is_file(), f"Missing long model fixture: {fixture}"
    primary_path = tmp_path / "segments.json"
    artifact_path = tmp_path / "artifact.json"
    subprocess.run(
        [
            str(transcribe_binary),
            str(fixture),
            "--silero-model",
            str(silero_model),
            "--asr-model-directory",
            str(model_directory),
            "--asr-model-size",
            model_size,
            "--threads",
            "2",
            "--output",
            str(primary_path),
            "--artifact-output",
            str(artifact_path),
        ],
        cwd=root,
        capture_output=True,
        text=True,
        check=True,
    )
    assert primary_path.is_file(), f"CLI did not create {primary_path}"
    assert artifact_path.is_file(), f"CLI did not create {artifact_path}"

    primary = json.loads(primary_path.read_text(encoding="utf-8"))
    artifact = json.loads(artifact_path.read_text(encoding="utf-8"))
    validate_asr_artifact(artifact)

    manifest_path = (
        app_directory
        / "Sources/MacAmbientJevPortableRuntime/Resources/qwen3_asr_models.json"
    )
    model_manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    expected_model = model_manifest[model_size]
    repository = expected_model["repository"]
    commit = expected_model["commit"]

    assert primary["schema_version"] == 1
    assert primary["asr"]["engine"] == "onnxruntime-qwen3-asr"
    assert primary["vad"]["engine"] == "onnxruntime-silero-vad"
    assert primary["asr"]["model"] == f"{repository}@{commit}"
    assert artifact["engine"]["name"] == "qwen3-asr"
    assert artifact["engine"]["backend"] == "onnxruntime"
    assert artifact["engine"]["model"] == repository
    assert artifact["engine"]["revision"] == commit
    assert artifact["runtime"]["audio_seconds"] == 18.464
    assert primary["runtime"] == artifact["runtime"]

    segments = primary["segments"]
    assert len(segments) >= 2, "The long fixture must produce multiple VAD segments"
    duration_ms = 18_464
    previous_end_ms = 0
    joined_text_parts: list[str] = []
    japanese_script = re.compile(r"[\u3040-\u30ff\u3400-\u9fff]")
    for segment in segments:
        start_ms = segment["start_ms"]
        end_ms = segment["end_ms"]
        text = segment["text"]
        assert isinstance(start_ms, int) and not isinstance(start_ms, bool)
        assert isinstance(end_ms, int) and not isinstance(end_ms, bool)
        assert 0 <= start_ms < end_ms <= duration_ms
        assert start_ms >= previous_end_ms, "VAD segments must be chronological and nonoverlapping"
        assert isinstance(text, str) and text.strip(), "Every VAD segment needs text"
        assert japanese_script.search(text), f"VAD segment is not Japanese: {text!r}"
        joined_text_parts.append(text)
        previous_end_ms = end_ms

    envelope_segments = artifact["segments"]
    assert len(envelope_segments) == 1
    assert "\n".join(joined_text_parts) == envelope_segments[0]["text"]

    reference = (
        "通信相手を認証したあと、セッション鍵を共有し、その鍵を使って以降の通信内容を暗号化する流れを考えます。"
        "今日の講義ではベイズ推定について説明します。この場合、公開鍵はどこで配布されるのでしょうか。"
    )
    reference_path = tmp_path / "reference.txt"
    reference_path.write_text(reference, encoding="utf-8")
    report_path = tmp_path / "report.json"
    subprocess.run(
        [
            str(evaluate_binary),
            str(reference_path),
            str(artifact_path),
            "--output",
            str(report_path),
        ],
        cwd=root,
        capture_output=True,
        text=True,
        check=True,
    )
    assert report_path.is_file(), f"Evaluator did not create {report_path}"
    report = json.loads(report_path.read_text(encoding="utf-8"))
    raw_cer = report["raw"]["rate"]
    normalized_cer = report["normalized"]["rate"]
    assert normalized_cer <= 0.15

    runtime = artifact["runtime"]
    print(
        "TranscribeFile model CLI diagnostics "
        f"size={model_size} duration_seconds={runtime['audio_seconds']} "
        f"rtf={runtime['rtf']} raw_cer={raw_cer} normalized_cer={normalized_cer} "
        f"segments={len(segments)} primary={primary_path} artifact={artifact_path} "
        f"reference={reference_path} report={report_path}"
    )
