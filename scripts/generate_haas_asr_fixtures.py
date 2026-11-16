#!/usr/bin/env python3
# /// script
# requires-python = "==3.12.*"
# dependencies = [
#   "onnxruntime==1.31.0",
#   "librosa==0.11.0",
#   "numpy==1.26.4",
#   "soundfile==0.13.1",
#   "sentencepiece==0.2.1",
# ]
# ///

import argparse
import hashlib
import importlib.metadata
import importlib.util
import json
import sys
from pathlib import Path

import soundfile as sf

REQUIRED_PACKAGES = {
    "onnxruntime": "1.31.0",
    "librosa": "0.11.0",
    "numpy": "1.26.4",
    "soundfile": "0.13.1",
    "sentencepiece": "0.2.1",
}
REFERENCE_SHA256 = "b709d2f6279275a04ae50c7991249566a8b8591af9fcbc754bfb363d9bd57177"


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate the Haas log-mel golden fixture.")
    parser.add_argument("--reference-dir", type=Path, required=True)
    args = parser.parse_args()

    for package, required_version in REQUIRED_PACKAGES.items():
        actual_version = importlib.metadata.version(package)
        if actual_version != required_version:
            raise ValueError(
                f"{package} must be {required_version}; found {actual_version}."
            )

    reference_path = args.reference_dir / "haas_ort.py"
    actual_hash = hashlib.sha256(reference_path.read_bytes()).hexdigest()
    if actual_hash != REFERENCE_SHA256:
        raise ValueError(
            f"Unexpected haas_ort.py SHA-256: expected {REFERENCE_SHA256}, "
            f"found {actual_hash}."
        )

    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location("haas_reference", reference_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Cannot load reference module: {reference_path}")
    reference = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(reference)

    repository_root = Path(__file__).resolve().parent.parent
    fixture_path = (
        repository_root
        / "app/MacAmbientJev/Tests/MacAmbientJevSpeechFixtures/Resources/"
        "qwen3_asr_voicevox_short.wav"
    )
    audio, sample_rate = sf.read(fixture_path, dtype="float32", frames=16000)
    if sample_rate != 16000 or audio.ndim != 1 or audio.shape != (16000,):
        raise ValueError(
            "The shared fixture must be mono, 16000 Hz, and exactly 16000 samples."
        )

    mel, valid_length = reference.logmel(audio)
    golden = {
        "shape": list(mel.shape),
        "validLength": int(valid_length),
        "values": mel.reshape(-1).tolist(),
    }
    output_path = (
        repository_root
        / "app/MacAmbientJev/Tests/MacAmbientJevHaasASRTests/Resources/"
        "haas_mel_golden.json"
    )
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(
        json.dumps(golden, separators=(",", ":"), allow_nan=False) + "\n",
        encoding="utf-8",
    )
    print(output_path)


if __name__ == "__main__":
    main()
