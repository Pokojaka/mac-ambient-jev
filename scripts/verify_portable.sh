#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE="$ROOT/app/MacAmbientJev"

python3 "$ROOT/scripts/fetch_onnxruntime.py"
model="$(python3 "$ROOT/scripts/fetch_silero_vad.py")"
export MAC_AMBIENT_JEV_SILERO_MODEL="$model"
printf 'Silero VAD model: %s\n' "$MAC_AMBIENT_JEV_SILERO_MODEL"
tokenizer="$(python3 "$ROOT/scripts/fetch_qwen3_asr_tokenizer.py")"
export MAC_AMBIENT_JEV_QWEN3_TOKENIZER="$tokenizer"
printf 'Qwen3-ASR tokenizer: %s\n' "$MAC_AMBIENT_JEV_QWEN3_TOKENIZER"
cd "$ROOT"
python3 -B scripts/test_fetch_silero_vad.py
python3 -B scripts/test_fetch_qwen3_asr_tokenizer.py
python3 -B scripts/test_fetch_qwen3_asr_model.py
python3 -B scripts/test_pinned_download.py
python3 -B scripts/test_generate_silero_reference.py
python3 -B scripts/test_generate_qwen3_asr_token_reference.py
python3 -B scripts/check_portable_core.py

swift package --package-path "$PACKAGE" dump-package >/dev/null
swift build --package-path "$PACKAGE"
swift test --package-path "$PACKAGE"

echo "Portable Core, Pipeline, and ONNX build/test verification passed"
