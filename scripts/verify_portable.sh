#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE="$ROOT/app/MacAmbientJev"

python3 "$ROOT/scripts/check_portable_core.py"   "$PACKAGE/Sources/MacAmbientJevCore"

swift package --package-path "$PACKAGE" dump-package >/dev/null
swift test   --package-path "$PACKAGE"   --filter MacAmbientJevCoreTests

echo "Portable Core verification passed"
