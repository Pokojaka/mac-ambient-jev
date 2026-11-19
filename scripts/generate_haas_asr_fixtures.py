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
import random
import sys
from pathlib import Path

import sentencepiece as spm
import soundfile as sf

REQUIRED_PACKAGES = {
    "onnxruntime": "1.31.0",
    "librosa": "0.11.0",
    "numpy": "1.26.4",
    "soundfile": "0.13.1",
    "sentencepiece": "0.2.1",
}
REFERENCE_SHA256 = "b709d2f6279275a04ae50c7991249566a8b8591af9fcbc754bfb363d9bd57177"
TOKENIZER_SHA256 = "9bd7bcdff62e43200001cd4c258d22e475b7b3b1e0f64f8be8e6e046f402f38c"


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Generate the Haas log-mel, SentencePiece, and end-to-end parity golden fixtures."
    )
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

    tokenizer_path = args.reference_dir / "tokenizer.model"
    actual_hash = hashlib.sha256(tokenizer_path.read_bytes()).hexdigest()
    if actual_hash != TOKENIZER_SHA256:
        raise ValueError(
            f"Unexpected tokenizer.model SHA-256: expected {TOKENIZER_SHA256}, "
            f"found {actual_hash}."
        )
    tokenizer = spm.SentencePieceProcessor(model_file=str(tokenizer_path))

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

    cases = [
        {"ids": [token_id], "expected": tokenizer.decode([token_id])}
        for token_id in range(3072)
    ]
    for ids in ([0], [33, 66], [227, 151, 130]):
        cases.append({"ids": ids, "expected": tokenizer.decode(ids)})
    # Python 3.12 random.Random uses the Mersenne Twister generator.
    rng = random.Random(146005)
    for _ in range(500):
        ids = [rng.randrange(3072) for _ in range(rng.randint(1, 40))]
        cases.append({"ids": ids, "expected": tokenizer.decode(ids)})
    tokenizer_output_path = (
        repository_root
        / "app/MacAmbientJev/Tests/MacAmbientJevHaasASRTests/Resources/"
        "haas_spm_golden.json"
    )
    tokenizer_output_path.parent.mkdir(parents=True, exist_ok=True)
    tokenizer_output_path.write_text(
        json.dumps({"cases": cases}, separators=(",", ":"), allow_nan=False)
        + "\n",
        encoding="utf-8",
    )
    print(tokenizer_output_path)

    encoder_session, decoder_session = reference.sessions(
        args.reference_dir / "int8dyn" / "encoder.onnx",
        args.reference_dir / "int8dyn" / "decoder_joint.onnx",
        threads=4,
    )
    reference_tokenizer = reference.Tokenizer(str(tokenizer_path))
    clips = []
    for name in ("short", "long"):
        resource_name = f"qwen3_asr_voicevox_{name}"
        audio = reference.load_wav(
            repository_root
            / "app/MacAmbientJev/Tests/MacAmbientJevSpeechFixtures/Resources"
            / f"{resource_name}.wav"
        )
        if name == "long":
            max_samples = 30 * 16000
            if len(audio) < max_samples:
                print(
                    f"{resource_name} is shorter than 30 seconds; "
                    f"using all {len(audio)} samples."
                )
            audio = audio[:max_samples]
        mel, valid_length = reference.logmel(audio)
        encoded, encoded_length = reference.encode(
            encoder_session, mel, valid_length
        )
        token_ids = reference.greedy_tdt(
            decoder_session, encoded, encoded_length
        )
        clips.append(
            {
                "resourceName": resource_name,
                "sampleCount": len(audio),
                "tokenIDs": token_ids,
                "text": reference_tokenizer.decode(token_ids),
            }
        )
    asr_output_path = (
        repository_root
        / "app/MacAmbientJev/Tests/MacAmbientJevHaasASRTests/Resources/"
        "haas_parity_golden.json"
    )
    asr_output_path.write_text(
        json.dumps({"clips": clips}, separators=(",", ":"), allow_nan=False)
        + "\n",
        encoding="utf-8",
    )
    print(asr_output_path)


if __name__ == "__main__":
    main()
