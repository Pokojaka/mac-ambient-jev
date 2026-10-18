#!/usr/bin/env python3

import struct
import subprocess
import sys
import tempfile
import wave
from pathlib import Path

PINNED_PACKAGE_VERSION = "1.51+dfsg-12build1"
SOURCE_RATE = 22050
TARGET_RATE = 16000
TARGET_BLOCK_FRAMES = 512
ORIGINAL_TEXT = "Hello, this is a speech recording for voice activity detection."


class FixtureError(Exception):
    pass


def require_package_version(package_name: str) -> None:
    try:
        result = subprocess.run(
            ["dpkg-query", "-W", "-f=${Version}", package_name],
            check=False,
            capture_output=True,
            text=True,
        )
    except FileNotFoundError as error:
        raise FixtureError("dpkg-query が見つかりません。Ubuntu 24.04 の固定環境で実行してください。") from error
    if result.returncode != 0:
        raise FixtureError(f"{package_name} の dpkg パッケージ情報を取得できません。")
    installed_version = result.stdout.strip()
    if installed_version != PINNED_PACKAGE_VERSION:
        raise FixtureError(
            f"{package_name} のバージョンは {PINNED_PACKAGE_VERSION} が必要です: {installed_version or '未インストール'}"
        )


def run_speech_engine(source_path: Path) -> None:
    try:
        result = subprocess.run(
            [
                "espeak-ng",
                "-v",
                "en-us",
                "-s",
                "150",
                "-p",
                "50",
                "-a",
                "100",
                "-w",
                str(source_path),
                ORIGINAL_TEXT,
            ],
            check=False,
            capture_output=True,
            text=True,
        )
    except FileNotFoundError as error:
        raise FixtureError("espeak-ng が見つかりません。固定バージョンをインストールしてください。") from error
    if result.returncode != 0:
        detail = result.stderr.strip()
        raise FixtureError(f"espeak-ng による音声生成に失敗しました: {detail or '詳細なし'}")


def read_source_samples(source_path: Path) -> tuple[int, list[int]]:
    try:
        with wave.open(str(source_path), "rb") as source:
            channels = source.getnchannels()
            sample_width = source.getsampwidth()
            sample_rate = source.getframerate()
            frame_count = source.getnframes()
            compression = source.getcomptype()
            if channels != 1 or sample_width != 2 or sample_rate != SOURCE_RATE or compression != "NONE":
                raise FixtureError(
                    "espeak-ng の WAV は 22050 Hz・モノラル・PCM16 の非圧縮形式である必要があります。"
                )
            frame_bytes = source.readframes(frame_count)
    except (EOFError, OSError, wave.Error) as error:
        raise FixtureError(f"espeak-ng の WAV を読み取れません: {error}") from error
    if len(frame_bytes) != frame_count * 2:
        raise FixtureError("espeak-ng の WAV フレーム数とデータ長が一致しません。")
    if frame_count == 0:
        raise FixtureError("espeak-ng の WAV に音声フレームがありません。")
    samples = [sample[0] for sample in struct.iter_unpack("<h", frame_bytes)]
    return sample_rate, samples


def round_ratio_ties_to_even(numerator: int, denominator: int) -> int:
    # Quotient/remainder rounding makes exact halfway samples independent of floating-point behavior.
    sign = -1 if numerator < 0 else 1
    quotient, remainder = divmod(abs(numerator), denominator)
    doubled_remainder = remainder * 2
    if doubled_remainder > denominator or (doubled_remainder == denominator and quotient % 2 == 1):
        quotient += 1
    return sign * quotient


def resample_linear(samples: list[int]) -> list[int]:
    output_count = (len(samples) * TARGET_RATE + SOURCE_RATE - 1) // SOURCE_RATE
    last_source_index = len(samples) - 1
    output = []
    for output_index in range(output_count):
        position_numerator = output_index * SOURCE_RATE
        left_index, fraction_numerator = divmod(position_numerator, TARGET_RATE)
        right_index = min(left_index + 1, last_source_index)
        weighted_numerator = (
            samples[left_index] * (TARGET_RATE - fraction_numerator)
            + samples[right_index] * fraction_numerator
        )
        sample = round_ratio_ties_to_even(weighted_numerator, TARGET_RATE)
        output.append(max(-32768, min(32767, sample)))
    return output


def make_pcm16_wav(samples: list[int]) -> bytes:
    padded_count = ((len(samples) + TARGET_BLOCK_FRAMES - 1) // TARGET_BLOCK_FRAMES) * TARGET_BLOCK_FRAMES
    padded_samples = samples + [0] * (padded_count - len(samples))
    frame_bytes = struct.pack(f"<{padded_count}h", *padded_samples)
    data_size = len(frame_bytes)
    wav_header = struct.pack(
        "<4sI4s4sIHHIIHH4sI",
        b"RIFF",
        36 + data_size,
        b"WAVE",
        b"fmt ",
        16,
        1,
        1,
        TARGET_RATE,
        TARGET_RATE * 2,
        2,
        16,
        b"data",
        data_size,
    )
    return wav_header + frame_bytes


def main() -> None:
    if sys.version_info < (3, 12):
        raise FixtureError("Python 3.12 以上が必要です。")
    if len(sys.argv) != 1:
        raise FixtureError("このスクリプトは引数を受け取りません。")

    require_package_version("espeak-ng")
    require_package_version("espeak-ng-data")

    repository_root = Path(__file__).resolve().parent.parent
    destination = repository_root / "app/MacAmbientJev/Tests/MacAmbientJevONNXTests/Resources/silero_speech.wav"
    if not destination.parent.is_dir():
        raise FixtureError(f"出力先ディレクトリがありません: {destination.parent}")

    with tempfile.TemporaryDirectory(prefix="silero-speech-fixture-") as temporary_directory:
        source_path = Path(temporary_directory) / "espeak_source.wav"
        run_speech_engine(source_path)
        source_rate, source_samples = read_source_samples(source_path)

    target_samples = resample_linear(source_samples)
    wav_data = make_pcm16_wav(target_samples)
    if len(wav_data) >= 200000:
        raise FixtureError(f"生成した WAV が 200000 bytes 以上です: {len(wav_data)}")
    destination.write_bytes(wav_data)
    print(
        f"入力: {source_rate} Hz・{len(source_samples)} samples; "
        f"変換後: {len(target_samples)} samples; "
        f"WAV: {len(wav_data)} bytes"
    )


if __name__ == "__main__":
    try:
        main()
    except FixtureError as error:
        print(f"エラー: {error}", file=sys.stderr)
        raise SystemExit(1) from error
