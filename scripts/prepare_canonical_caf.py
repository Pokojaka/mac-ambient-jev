"""Converts a 16 kHz mono 16-bit PCM WAV into the canonical CAF both platforms read.

The CAF holds Float32 little-endian samples (value / 32768) in a `desc` and a `data` chunk, the
format `CanonicalCAFReader` accepts. Prints the output path, sample count and SHA-256 as JSON.
The output is created exclusively and never replaces an existing file.
"""
from __future__ import annotations

import argparse
import array
import hashlib
import json
import struct
import sys
import wave
from pathlib import Path

SAMPLE_RATE = 16_000
FLOAT_LITTLE_ENDIAN_FLAGS = 3


def canonical_caf_bytes(wav_path: Path) -> tuple[bytes, int]:
    with wave.open(str(wav_path), "rb") as wav:
        if (wav.getframerate(), wav.getnchannels(), wav.getsampwidth()) != (SAMPLE_RATE, 1, 2):
            raise ValueError(f"{wav_path} must be 16 kHz mono 16-bit PCM")
        frames = wav.getnframes()
        pcm = array.array("h")
        pcm.frombytes(wav.readframes(frames))
    if sys.byteorder == "big":
        pcm.byteswap()
    if len(pcm) != frames or frames == 0:
        raise ValueError(f"{wav_path} has no complete samples")
    samples = struct.pack(f"<{frames}f", *(value / 32768.0 for value in pcm))
    description = struct.pack(">dIIIIII", float(SAMPLE_RATE), 0x6C70636D, FLOAT_LITTLE_ENDIAN_FLAGS, 4, 1, 1, 32)
    data = struct.pack(">I", 0) + samples
    caf = (
        b"caff" + struct.pack(">HH", 1, 0)
        + b"desc" + struct.pack(">q", len(description)) + description
        + b"data" + struct.pack(">q", len(data)) + data
    )
    return caf, frames


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--wav", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        caf, frames = canonical_caf_bytes(args.wav)
        with args.output.open("xb") as handle:
            handle.write(caf)
    except (OSError, ValueError, wave.Error) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(json.dumps({"path": str(args.output), "sample_count": frames, "sha256": hashlib.sha256(caf).hexdigest()}))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
