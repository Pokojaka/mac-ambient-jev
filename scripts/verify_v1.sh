#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE="$ROOT/app/MacAmbientJev"

swift package --package-path "$PACKAGE" resolve
swift build --package-path "$PACKAGE"
swift test --package-path "$PACKAGE"
swift build \
  --package-path "$PACKAGE" \
  --product MacAmbientJevProcessRecording
swift build \
  --package-path "$PACKAGE" \
  --product MacAmbientJevEvaluateSession

for tool in "$ROOT"/tools/*.swift; do
  swiftc -typecheck "$tool"
done

if [[ "${RUN_MODEL_TESTS:-0}" == "1" ]]; then
  swift test \
    --package-path "$PACKAGE" \
    --filter ASRIntegrationTests
fi

bash "$ROOT/scripts/build_app.sh"

echo "V1 verification passed"
