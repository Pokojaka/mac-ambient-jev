#!/usr/bin/env python3
"""Generate credited VOICEVOX (ずんだもん・ノーマル) fixtures for Qwen3-ASR tests.

Preserve the applicable VOICEVOX and ZUNKO usage terms when redistributing output.
Start the engine pinned by IMAGE on PLATFORM before running this script; the caller
owns the Docker lifecycle. The default /audio_query parameters are intentionally
left to the pinned engine and checked against the expected values below.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import struct
import sys
import tempfile
import wave
from pathlib import Path
from typing import Any


IMAGE = "voicevox/voicevox_engine@sha256:52bfd61345fe6896a3d0014e0efd1931f6d2f91f501f3c27181e7bce05b47d68"
PLATFORM = "linux/arm64"
ENGINE_VERSION = "0.25.2"
SPEAKER_UUID = "388f246b-8c41-4ac1-8e2d-5d79f3ff56d9"
SPEAKER_NAME = "ずんだもん"
STYLE_ID = 3
STYLE_NAME = "ノーマル"
SOURCE_RATE = 24_000
TARGET_RATE = 16_000

EXPECTED_QUERY_PARAMETERS: dict[str, bool | int | float] = {
    "speedScale": 1.0,
    "pitchScale": 0.0,
    "intonationScale": 1.0,
    "volumeScale": 1.0,
    "prePhonemeLength": 0.1,
    "postPhonemeLength": 0.1,
    "outputSamplingRate": 24_000,
    "outputStereo": False,
}

SHORT_CORPUS_IDS = ("general-001",)
LONG_CORPUS_IDS = ("long-001", "statistics-001", "question-001")
OUTPUT_NAMES = {
    "short": "qwen3_asr_voicevox_short.wav",
    "long": "qwen3_asr_voicevox_long.wav",
}
REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
CORPUS_PATH = REPOSITORY_ROOT / "tools/corpora/voicevox-ja-core-v1.json"
RESOURCE_DIRECTORY = (
    REPOSITORY_ROOT
    / "app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/Resources"
)

sys.path.insert(0, str(REPOSITORY_ROOT / "tools/linux-audio"))
from common import voicevox_cli


class FixtureError(Exception):
    """An actionable failure while generating a public ASR test fixture."""


def require_python_version() -> None:
    if sys.version_info < (3, 12):
        raise FixtureError("Python 3.12 以上が必要です。")


def load_fixture_texts(corpus_path: Path) -> dict[str, str]:
    try:
        corpus = json.loads(corpus_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise FixtureError(f"VOICEVOX コーパスを読み取れません: {error}") from error
    utterances = corpus.get("utterances") if isinstance(corpus, dict) else None
    if not isinstance(utterances, list):
        raise FixtureError("VOICEVOX コーパスに utterances 配列がありません。")

    texts_by_id: dict[str, list[str]] = {}
    for utterance in utterances:
        if not isinstance(utterance, dict):
            continue
        utterance_id = utterance.get("id")
        if utterance_id in (*SHORT_CORPUS_IDS, *LONG_CORPUS_IDS):
            text = utterance.get("text")
            if not isinstance(text, str):
                raise FixtureError(f"コーパス ID {utterance_id} の text が文字列ではありません。")
            texts_by_id.setdefault(utterance_id, []).append(text)

    required_ids = (*SHORT_CORPUS_IDS, *LONG_CORPUS_IDS)
    for utterance_id in required_ids:
        texts = texts_by_id.get(utterance_id, [])
        if not texts:
            raise FixtureError(f"VOICEVOX コーパスに必要な ID がありません: {utterance_id}")
        if len(texts) != 1:
            raise FixtureError(f"VOICEVOX コーパスの ID が重複しています: {utterance_id}")

    short_text = "".join(texts_by_id[utterance_id][0] for utterance_id in SHORT_CORPUS_IDS)
    long_text = "".join(texts_by_id[utterance_id][0] for utterance_id in LONG_CORPUS_IDS)
    return {"short": short_text, "long": long_text}


def validate_engine(base_url: str) -> None:
    try:
        actual_version = voicevox_cli.engine_version(base_url)
    except Exception as error:
        raise FixtureError(f"VOICEVOX ENGINE のバージョンを取得できません: {error}") from error
    if actual_version != ENGINE_VERSION:
        raise FixtureError(
            f"VOICEVOX ENGINE は {ENGINE_VERSION} が必要です: {actual_version!r}"
        )

    try:
        styles = voicevox_cli.voice_styles(base_url)
    except Exception as error:
        raise FixtureError(f"VOICEVOX の speaker/style を取得できません: {error}") from error
    matching_speakers = [style for style in styles if style.speaker_uuid == SPEAKER_UUID]
    if len(matching_speakers) != 1:
        raise FixtureError(
            f"VOICEVOX speaker UUID {SPEAKER_UUID} が一意に見つかりません。"
        )
    style = matching_speakers[0]
    actual = (style.speaker_name, style.style_id, style.style_name)
    expected = (SPEAKER_NAME, STYLE_ID, STYLE_NAME)
    if actual != expected:
        raise FixtureError(
            "VOICEVOX の speaker/style が一致しません: "
            f"expected={(SPEAKER_UUID, *expected)!r}, actual={(style.speaker_uuid, *actual)!r}"
        )


def validate_audio_query(audio_query: Any) -> None:
    if not isinstance(audio_query, dict):
        raise FixtureError(f"VOICEVOX audio_query が object ではありません: {audio_query!r}")
    for key, expected in EXPECTED_QUERY_PARAMETERS.items():
        if key not in audio_query:
            raise FixtureError(f"VOICEVOX audio_query に {key} がありません。")
        actual = audio_query[key]
        if isinstance(expected, bool):
            matches = type(actual) is bool and actual is expected
        else:
            matches = type(actual) in (int, float) and actual == expected
        if not matches:
            raise FixtureError(
                f"VOICEVOX audio_query の {key} が想定値と異なります: "
                f"expected={expected!r}, actual={actual!r}"
            )


def _data_chunk_size(wav_data: bytes) -> int:
    offset = 12
    data_sizes: list[int] = []
    while offset < len(wav_data):
        if offset + 8 > len(wav_data):
            raise FixtureError("VOICEVOX の WAV に不完全な chunk header があります。")
        chunk_id = wav_data[offset : offset + 4]
        chunk_size = struct.unpack_from("<I", wav_data, offset + 4)[0]
        chunk_end = offset + 8 + chunk_size
        padded_end = chunk_end + (chunk_size & 1)
        if padded_end > len(wav_data):
            raise FixtureError("VOICEVOX の WAV chunk がファイル末尾より長くなっています。")
        if chunk_id == b"data":
            data_sizes.append(chunk_size)
        offset = padded_end
    if len(data_sizes) != 1:
        raise FixtureError("VOICEVOX の WAV に data chunk が一つだけ存在する必要があります。")
    return data_sizes[0]


def read_source_samples(source_path: Path) -> list[int]:
    try:
        wav_data = source_path.read_bytes()
        if len(wav_data) < 12 or wav_data[:4] != b"RIFF" or wav_data[8:12] != b"WAVE":
            raise FixtureError("VOICEVOX の出力に完全な RIFF/WAVE ヘッダーがありません。")
        riff_size = struct.unpack_from("<I", wav_data, 4)[0]
        if riff_size != len(wav_data) - 8:
            raise FixtureError("VOICEVOX の WAV の RIFF サイズがファイル長と一致しません。")
        data_size = _data_chunk_size(wav_data)
        if data_size % 2:
            raise FixtureError("VOICEVOX の WAV data chunk に不完全な PCM16 sample があります。")
        with wave.open(io.BytesIO(wav_data), "rb") as source:
            channels = source.getnchannels()
            sample_width = source.getsampwidth()
            sample_rate = source.getframerate()
            frame_count = source.getnframes()
            compression = source.getcomptype()
            if (
                channels != 1
                or sample_width != 2
                or sample_rate != SOURCE_RATE
                or compression != "NONE"
            ):
                raise FixtureError(
                    "VOICEVOX の WAV は 24000 Hz・モノラル・PCM16 の非圧縮形式である必要があります。"
                )
            frame_bytes = source.readframes(frame_count)
    except FixtureError:
        raise
    except (EOFError, OSError, wave.Error, struct.error) as error:
        raise FixtureError(f"VOICEVOX の WAV を読み取れません: {error}") from error

    if frame_count == 0:
        raise FixtureError("VOICEVOX の WAV に音声フレームがありません。")
    if data_size != frame_count * 2 or len(frame_bytes) != frame_count * 2:
        raise FixtureError("VOICEVOX の WAV フレーム数とデータ長が一致しません。")
    return [sample[0] for sample in struct.iter_unpack("<h", frame_bytes)]


def round_ratio_ties_to_even(numerator: int, denominator: int) -> int:
    quotient, remainder = divmod(abs(numerator), denominator)
    doubled_remainder = remainder * 2
    if doubled_remainder > denominator or (
        doubled_remainder == denominator and quotient % 2 == 1
    ):
        quotient += 1
    return (-1 if numerator < 0 else 1) * quotient


def resample_linear(samples: list[int]) -> list[int]:
    if not samples:
        raise FixtureError("リサンプリングする音声フレームがありません。")
    output_count = (len(samples) * 2 + 2) // 3
    last_source_index = len(samples) - 1
    output: list[int] = []
    for output_index in range(output_count):
        position_numerator = output_index * 3
        left_index, fraction_numerator = divmod(position_numerator, 2)
        right_index = min(left_index + 1, last_source_index)
        weighted_numerator = (
            samples[left_index] * (2 - fraction_numerator)
            + samples[right_index] * fraction_numerator
        )
        sample = round_ratio_ties_to_even(weighted_numerator, 2)
        output.append(max(-32_768, min(32_767, sample)))
    return output


def make_pcm16_wav(samples: list[int]) -> bytes:
    if not samples:
        raise FixtureError("出力する音声フレームがありません。")
    frame_bytes = struct.pack(f"<{len(samples)}h", *samples)
    data_size = len(frame_bytes)
    header = struct.pack(
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
    return header + frame_bytes


def validate_duration(name: str, frame_count: int) -> None:
    duration = frame_count / TARGET_RATE
    if name == "short":
        valid = 3 <= duration <= 6
        expected = "3 <= duration <= 6 seconds"
    else:
        valid = 15 < duration <= 30
        expected = "15 < duration <= 30 seconds"
    if not valid:
        raise FixtureError(
            f"{name} fixture の長さが不正です: {duration:.6f} seconds; {expected} が必要です。"
        )


def generate(*, base_url: str, destination: Path) -> None:
    require_python_version()
    if not destination.is_dir():
        raise FixtureError(f"出力先リソースディレクトリがありません: {destination}")

    texts = load_fixture_texts(CORPUS_PATH)
    validate_engine(base_url)
    prepared_outputs: dict[str, tuple[Path, bytes, str]] = {}

    try:
        with tempfile.TemporaryDirectory(prefix="qwen3-asr-voicevox-") as temporary_directory:
            temporary_root = Path(temporary_directory)
            for name in ("short", "long"):
                source_path = temporary_root / f"{name}_source.wav"
                audio_query = voicevox_cli.synthesize(
                    base_url=base_url,
                    text=texts[name],
                    style_id=STYLE_ID,
                    output=source_path,
                )
                validate_audio_query(audio_query)
                source_samples = read_source_samples(source_path)
                target_samples = resample_linear(source_samples)
                validate_duration(name, len(target_samples))
                wav_data = make_pcm16_wav(target_samples)
                prepared_outputs[name] = (
                    destination / OUTPUT_NAMES[name],
                    wav_data,
                    hashlib.sha256(wav_data).hexdigest(),
                )
    except FixtureError:
        raise
    except Exception as error:
        raise FixtureError(f"VOICEVOX 音声の生成に失敗しました: {error}") from error

    # Both fixtures are synthesized and validated before either final file is written.
    for name in ("short", "long"):
        output_path, wav_data, digest = prepared_outputs[name]
        output_path.write_bytes(wav_data)
        duration = (len(wav_data) - 44) // 2 / TARGET_RATE
        print(
            f"{name}: text={texts[name]!r}; sample_frames={(len(wav_data) - 44) // 2}; "
            f"duration_seconds={duration:.6f}; sha256={digest}"
        )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", required=True)
    args = parser.parse_args()
    try:
        generate(base_url=args.base_url, destination=RESOURCE_DIRECTORY)
    except FixtureError as error:
        print(f"エラー: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
