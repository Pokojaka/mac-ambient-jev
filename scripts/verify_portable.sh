#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE="$ROOT/app/MacAmbientJev"

python3 "$ROOT/scripts/fetch_onnxruntime.py"
cd "$ROOT"
python3 -B scripts/check_portable_core.py

swift package --package-path "$PACKAGE" dump-package >/dev/null
swift build --package-path "$PACKAGE"
swift test --package-path "$PACKAGE"

echo "Portable Core, Pipeline, and ONNX build/test verification passed"
