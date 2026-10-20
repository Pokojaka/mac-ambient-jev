#!/usr/bin/env python3
"""FFmpeg 8.0 で Windows 用の決定的な音声 codec fixture を一つ生成します。"""
from __future__ import annotations

import argparse
import math
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import wave


SAMPLE_RATE = 48_000
FRAME_COUNT = 12_288
FREQUENCY_HZ = 375
CHANNEL_GAINS = (0.5, 0.25)
PCM_SCALE = 32_768
WAV_CHUNK_FRAMES = 256
MARKER_CHIRP_START_FRAME = 3_072
MARKER_CHIRP_FRAME_COUNT = 512
MARKER_SILENCE_GAP_START_FRAME = MARKER_CHIRP_START_FRAME + MARKER_CHIRP_FRAME_COUNT
MARKER_SINE_START_FRAME = 6_144
MARKER_CHIRP_START_FREQUENCY_HZ = 700
MARKER_CHIRP_END_FREQUENCY_HZ = 3_700
MARKER_CHIRP_DURATION_SECONDS = MARKER_CHIRP_FRAME_COUNT / SAMPLE_RATE
MAX_FIXTURE_BYTES = 100_000
FORMATS = ("flac", "mp3", "m4a", "aac")


class FixtureGenerationError(Exception):
    """An actionable failure while generating a compressed fixture."""


def _quantize_pcm16(value: float) -> int:
    """Round half away from zero, then return one signed PCM16 sample."""
    scaled = value * PCM_SCALE
    sample = math.floor(scaled + 0.5) if scaled >= 0 else math.ceil(scaled - 0.5)
    return max(-PCM_SCALE, min(PCM_SCALE - 1, sample))


def _write_source_wav(path: Path, audio_format: str) -> None:
    """Write the source in bounded chunks without retaining the full signal."""
    use_marker_waveform = audio_format in ("m4a", "aac")
    with wave.open(str(path), "wb") as wav_file:
        wav_file.setnchannels(2)
        wav_file.setsampwidth(2)
        wav_file.setframerate(SAMPLE_RATE)
        wav_file.setcomptype("NONE", "not compressed")

        for first_frame in range(0, FRAME_COUNT, WAV_CHUNK_FRAMES):
            frames_in_chunk = min(WAV_CHUNK_FRAMES, FRAME_COUNT - first_frame)
            chunk = bytearray()
            for frame_index in range(first_frame, first_frame + frames_in_chunk):
                if use_marker_waveform and frame_index < MARKER_CHIRP_START_FRAME:
                    signal = 0.0
                elif use_marker_waveform and frame_index < MARKER_SILENCE_GAP_START_FRAME:
                    chirp_time = (frame_index - MARKER_CHIRP_START_FRAME) / SAMPLE_RATE
                    chirp_slope = (
                        (MARKER_CHIRP_END_FREQUENCY_HZ - MARKER_CHIRP_START_FREQUENCY_HZ)
                        / MARKER_CHIRP_DURATION_SECONDS
                    )
                    phase = 2.0 * math.pi * (
                        MARKER_CHIRP_START_FREQUENCY_HZ * chirp_time
                        + 0.5 * chirp_slope * chirp_time * chirp_time
                    )
                    signal = math.sin(phase)
                elif use_marker_waveform and frame_index < MARKER_SINE_START_FRAME:
                    signal = 0.0
                else:
                    phase = 2.0 * math.pi * FREQUENCY_HZ * frame_index / SAMPLE_RATE
                    signal = math.sin(phase)
                left = _quantize_pcm16(signal * CHANNEL_GAINS[0])
                right = _quantize_pcm16(signal * CHANNEL_GAINS[1])
                chunk.extend(struct.pack("<hh", left, right))
            wav_file.writeframesraw(chunk)


def _find_ffmpeg() -> str:
    executable = shutil.which("ffmpeg")
    if executable is None:
        raise FixtureGenerationError("PATH 上に ffmpeg がありません")

    try:
        result = subprocess.run(
            [executable, "-version"],
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError as exc:
        raise FixtureGenerationError(f"ffmpeg のバージョンを確認できません: {exc}") from exc

    if result.returncode != 0:
        detail = result.stderr.strip() or f"終了コード {result.returncode}"
        raise FixtureGenerationError(f"ffmpeg -version に失敗しました: {detail}")

    first_line = result.stdout.splitlines()[0] if result.stdout.splitlines() else ""
    match = re.match(r"^ffmpeg version ([^\s]+)(?:\s|$)", first_line)
    version = match.group(1) if match else "不明"
    if version != "8.0":
        raise FixtureGenerationError(
            f"ffmpeg のバージョンは 8.0 が必要です（検出: {version}）"
        )
    return executable


def _ffmpeg_command(ffmpeg: str, source: Path, encoded: Path, audio_format: str) -> list[str]:
    command = [
        ffmpeg,
        "-hide_banner",
        "-nostdin",
        "-loglevel",
        "error",
        "-n",
        "-i",
        str(source),
        "-map",
        "0:a:0",
        "-map_metadata",
        "-1",
        "-fflags",
        "+bitexact",
        "-flags:a",
        "+bitexact",
        "-threads",
        "1",
        "-ar",
        str(SAMPLE_RATE),
        "-ac",
        "2",
    ]

    if audio_format == "flac":
        command.extend(["-c:a", "flac", "-compression_level", "5", "-sample_fmt", "s16"])
        muxer = "flac"
    elif audio_format == "mp3":
        command.extend(["-c:a", "libmp3lame", "-b:a", "192k", "-write_xing", "1"])
        muxer = "mp3"
    elif audio_format in ("m4a", "aac"):
        command.extend(["-c:a", "aac", "-b:a", "192k", "-profile:a", "aac_low"])
        if audio_format == "m4a":
            muxer = "mp4"
        else:
            muxer = "adts"
    else:
        raise FixtureGenerationError(f"未対応の形式です: {audio_format}")

    command.extend(["-f", muxer, str(encoded)])
    return command


def _existing_compressed_fixture_bytes(directory: Path) -> int:
    total = 0
    try:
        for path in directory.iterdir():
            if path.suffix.lower().lstrip(".") in FORMATS and path.is_file():
                total += path.stat().st_size
    except OSError as exc:
        raise FixtureGenerationError(f"出力先ディレクトリを確認できません: {exc}") from exc
    return total


def generate(audio_format: str, requested_output: Path) -> Path:
    output = requested_output.expanduser().resolve()
    if os.path.lexists(output):
        raise FixtureGenerationError(
            f"出力先は既に存在します。検証後に手動で削除してから再生成してください: {output}"
        )
    if not output.parent.is_dir():
        raise FixtureGenerationError(f"出力先ディレクトリがありません: {output.parent}")

    ffmpeg = _find_ffmpeg()
    suffix = f".{audio_format}"
    try:
        with tempfile.TemporaryDirectory(
            prefix="windows-audio-fixture-", dir=output.parent
        ) as temporary_directory:
            temporary = Path(temporary_directory)
            source = temporary / "source.wav"
            encoded = temporary / f"fixture{suffix}"
            _write_source_wav(source, audio_format)

            command = _ffmpeg_command(ffmpeg, source, encoded, audio_format)
            try:
                result = subprocess.run(command, check=False, capture_output=True, text=True)
            except OSError as exc:
                raise FixtureGenerationError(f"ffmpeg を実行できません: {exc}") from exc
            if result.returncode != 0:
                detail = result.stderr.strip() or f"終了コード {result.returncode}"
                raise FixtureGenerationError(f"ffmpeg のエンコードに失敗しました: {detail}")

            if not encoded.is_file():
                raise FixtureGenerationError("ffmpeg が出力ファイルを作成しませんでした")
            encoded_size = encoded.stat().st_size
            if encoded_size <= 0:
                raise FixtureGenerationError("ffmpeg の出力サイズが 0 バイトです")

            committed_total = _existing_compressed_fixture_bytes(output.parent)
            if committed_total + encoded_size >= MAX_FIXTURE_BYTES:
                raise FixtureGenerationError(
                    "圧縮 fixture の合計サイズは 100000 バイト未満である必要があります "
                    f"（生成分込み: {committed_total + encoded_size} バイト）"
                )

            try:
                # Linking publishes the completed file atomically and never overwrites.
                os.link(encoded, output)
            except FileExistsError as exc:
                raise FixtureGenerationError(
                    f"出力先は既に存在します。検証後に手動で削除してから再生成してください: {output}"
                ) from exc
            except OSError as exc:
                raise FixtureGenerationError(f"出力先へ安全に配置できません: {exc}") from exc

    except FixtureGenerationError:
        raise
    except OSError as exc:
        raise FixtureGenerationError(f"fixture の生成に失敗しました: {exc}") from exc

    if not output.is_file() or output.stat().st_size <= 0:
        raise FixtureGenerationError("生成後の出力ファイルが存在しないか、サイズが 0 バイトです")
    final_total = _existing_compressed_fixture_bytes(output.parent)
    if output.suffix.lower().lstrip(".") not in FORMATS:
        final_total += output.stat().st_size
    if final_total >= MAX_FIXTURE_BYTES:
        raise FixtureGenerationError(
            "圧縮 fixture の合計サイズは 100000 バイト未満である必要があります "
            f"（配置後: {final_total} バイト）"
        )
    return output


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--format", choices=FORMATS, required=True, help="出力形式")
    parser.add_argument("--output", type=Path, required=True, help="新規作成する出力ファイル")
    options = parser.parse_args()

    try:
        output = generate(options.format, options.output)
    except FixtureGenerationError as exc:
        print(f"エラー: {exc}", file=sys.stderr)
        return 1
    print(f"生成しました: {output} ({output.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
