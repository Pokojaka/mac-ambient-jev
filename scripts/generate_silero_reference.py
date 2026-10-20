#!/usr/bin/env python3

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import urllib.request
import wave
from pathlib import Path
from types import ModuleType
from typing import Any

import fetch_silero_vad


WRAPPER_URL = (
    "https://raw.githubusercontent.com/snakers4/silero-vad/"
    "5cd7945676eb32225748052e2e6a0580e4686a08/src/silero_vad/utils_vad.py"
)
WRAPPER_SHA256 = "15d0f6b3ef9590e22ca2f146e1436f6901da356cb552d3183df4100862b333cb"
SAMPLE_RATE = 16000
FRAME_SAMPLES = 512
EXPECTED_FRAME_COUNT = 141
REFERENCE_INDICES = (0, 1, 2, 4, 8, 16, 32, 48, 64, 80, 100, 120, 140)
SILENCE_FRAME_COUNT = 64


class JapaneseArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        raise ValueError(f"コマンドライン引数が不正です: {message}")


def sha256_file(path: Path) -> str:
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def load_upstream_wrapper() -> tuple[ModuleType, str]:
    with urllib.request.urlopen(WRAPPER_URL, timeout=60) as response:
        source = response.read()
    actual_sha256 = hashlib.sha256(source).hexdigest()
    if actual_sha256 != WRAPPER_SHA256:
        raise ValueError(
            "上流 Silero ラッパーの SHA-256 が一致しません: "
            f"期待値 {WRAPPER_SHA256}、実際 {actual_sha256}。"
        )

    module = ModuleType("_silero_reference_upstream_utils_vad")
    module.__file__ = WRAPPER_URL
    exec(compile(source, WRAPPER_URL, "exec"), module.__dict__)
    return module, actual_sha256


def read_audio(audio_path: Path, numpy: Any) -> tuple[Any, str]:
    try:
        with wave.open(str(audio_path), "rb") as source:
            channels = source.getnchannels()
            sample_width = source.getsampwidth()
            sample_rate = source.getframerate()
            frame_count = source.getnframes()
            compression = source.getcomptype()
            if channels != 1 or sample_width != 2 or sample_rate != SAMPLE_RATE or compression != "NONE":
                raise ValueError("音声 fixture は非圧縮 PCM16・モノラル・16000 Hz である必要があります。")
            frame_bytes = source.readframes(frame_count)
    except (EOFError, OSError, wave.Error) as error:
        raise ValueError(f"音声 fixture を WAV として読み取れません: {error}") from error

    if len(frame_bytes) != frame_count * 2:
        raise ValueError("音声 fixture のフレーム数と PCM データ長が一致しません。")
    if frame_count == 0 or frame_count % FRAME_SAMPLES != 0:
        raise ValueError("音声 fixture は空でなく、512 サンプル単位である必要があります。")

    audio = numpy.frombuffer(frame_bytes, dtype="<i2").astype(numpy.float32) / numpy.float32(32768)
    if len(audio) // FRAME_SAMPLES != EXPECTED_FRAME_COUNT:
        raise ValueError(
            f"音声 fixture は {EXPECTED_FRAME_COUNT} フレームである必要があります: "
            f"実際 {len(audio) // FRAME_SAMPLES} フレーム。"
        )
    return audio, hashlib.sha256(audio_path.read_bytes()).hexdigest()


def generate_reference(model_argument: Path) -> None:
    import importlib.metadata

    import numpy
    import onnxruntime
    import torch

    model_path = model_argument.resolve(strict=True)
    if not model_path.is_file():
        raise ValueError(f"モデルパスが通常ファイルではありません: {model_path}")
    model_sha256 = sha256_file(model_path)
    if model_sha256 != fetch_silero_vad.SHA256:
        raise ValueError(
            "Silero VAD モデルの SHA-256 が一致しません: "
            f"期待値 {fetch_silero_vad.SHA256}、実際 {model_sha256}。"
        )

    onnxruntime_version = onnxruntime.__version__
    if onnxruntime_version != "1.31.0":
        raise ValueError(f"onnxruntime は 1.31.0 が必要です: 実際 {onnxruntime_version}。")

    repository_root = Path(__file__).resolve().parent.parent
    audio_path = (
        repository_root
        / "app/MacAmbientJev/Tests/MacAmbientJevONNXTests/Resources/silero_speech.wav"
    )
    if not audio_path.is_file():
        raise ValueError(f"固定音声 fixture がありません: {audio_path}")
    audio, audio_sha256 = read_audio(audio_path, numpy)
    frame_count = len(audio) // FRAME_SAMPLES
    if any(index >= frame_count for index in REFERENCE_INDICES):
        raise ValueError("固定参照フレーム番号が音声 fixture の範囲外です。")

    wrapper_module, wrapper_sha256 = load_upstream_wrapper()
    torch.set_num_threads(1)
    wrapper = wrapper_module.OnnxWrapper(str(model_path), force_onnx_cpu=True)

    probabilities = []
    voiced_frame_count = 0
    voiced_above_threshold_count = 0
    for frame_index in range(frame_count):
        start = frame_index * FRAME_SAMPLES
        frame = audio[start : start + FRAME_SAMPLES]
        mean_square = numpy.mean(numpy.square(frame.astype(numpy.float64)), dtype=numpy.float64)
        is_voiced = numpy.sqrt(mean_square) >= 0.01
        probability = float(wrapper(torch.from_numpy(frame), SAMPLE_RATE).item())
        probabilities.append(probability)
        if is_voiced:
            voiced_frame_count += 1
            if probability >= 0.5:
                voiced_above_threshold_count += 1

    if voiced_frame_count == 0:
        raise ValueError("音声 fixture に RMS 0.01 以上の有声フレームがありません。")

    wrapper.reset_states()
    silence_frame = torch.zeros(FRAME_SAMPLES, dtype=torch.float32)
    silence_probabilities = [
        float(wrapper(silence_frame, SAMPLE_RATE).item())
        for _ in range(SILENCE_FRAME_COUNT)
    ]
    silence_max_probability = max(silence_probabilities)
    voiced_fraction = voiced_above_threshold_count / voiced_frame_count
    if voiced_fraction < 0.70:
        raise ValueError("有声フレームの確率 0.5 以上の割合は 70% 以上である必要があります。")
    if any(probability >= 0.1 for probability in silence_probabilities):
        raise ValueError("無音フレームの確率は 0.1 未満である必要があります。")

    references = [
        {"frameIndex": index, "probability": probabilities[index]}
        for index in REFERENCE_INDICES
    ]
    reference_data = {
        "modelCommit": fetch_silero_vad.COMMIT,
        "modelSHA256": model_sha256,
        "wrapperSHA256": wrapper_sha256,
        "audioSHA256": audio_sha256,
        "sampleRate": SAMPLE_RATE,
        "frameSamples": FRAME_SAMPLES,
        "frameCount": frame_count,
        "onnxruntimeVersion": onnxruntime_version,
        "numpyVersion": numpy.__version__,
        "torchVersion": torch.__version__,
        "references": references,
    }

    output_path = (
        repository_root
        / "app/MacAmbientJev/Tests/MacAmbientJevONNXTests/Resources/silero_reference.json"
    )
    if not output_path.parent.is_dir():
        raise ValueError(f"参照 JSON の出力先ディレクトリがありません: {output_path.parent}")
    output_path.write_text(
        json.dumps(reference_data, indent=2, ensure_ascii=False, allow_nan=False) + "\n",
        encoding="utf-8",
    )

    packaging_version = importlib.metadata.version("packaging")
    print(f"onnxruntime: {onnxruntime_version}")
    print(f"numpy: {numpy.__version__}")
    print(f"torch: {torch.__version__}")
    print(f"packaging: {packaging_version}")
    print(f"modelSHA256: {model_sha256}")
    print(f"wrapperSHA256: {wrapper_sha256}")
    print(f"audioSHA256: {audio_sha256}")
    print(f"frameCount: {frame_count}")
    print(
        f"voicedFrames: {voiced_frame_count}; "
        f"probabilityAtLeast0.5: {voiced_above_threshold_count}; "
        f"fraction: {voiced_fraction:.6f}"
    )
    print(
        f"silenceFrames: {len(silence_probabilities)}; "
        f"probabilityBelow0.1: "
        f"{sum(probability < 0.1 for probability in silence_probabilities)}; "
        f"maximumProbability: {silence_max_probability:.9g}"
    )
    print(
        "references: "
        + ", ".join(
            f"{reference['frameIndex']}={reference['probability']!r}"
            for reference in references
        )
    )


def main() -> int:
    parser = JapaneseArgumentParser(description="Silero のフレーム単位の参照確率を生成します。")
    parser.add_argument("--model", type=Path, required=True, help="SHA-256 検証済み ONNX モデル")
    try:
        arguments = parser.parse_args()
        generate_reference(arguments.model)
    except Exception as error:
        print(f"エラー: Silero 参照データを生成できません: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
