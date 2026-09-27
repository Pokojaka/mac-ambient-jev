#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE="$ROOT/app/MacAmbientJev"

if [[ "${RUN_MODEL_TESTS:-0}" == "1" ]]; then
  : "${ASR_SMOKE_AUDIO:?RUN_MODEL_TESTS=1 requires ASR_SMOKE_AUDIO to name an absolute WAV file}"
  if [[ "$ASR_SMOKE_AUDIO" != /* ]]; then
    echo "ASR_SMOKE_AUDIO must be an absolute path: $ASR_SMOKE_AUDIO" >&2
    exit 1
  fi
  if [[ ! -f "$ASR_SMOKE_AUDIO" || ! -r "$ASR_SMOKE_AUDIO" ]]; then
    echo "ASR_SMOKE_AUDIO must be a readable file: $ASR_SMOKE_AUDIO" >&2
    exit 1
  fi
  export RUN_MODEL_TESTS ASR_SMOKE_AUDIO
fi

swift package --package-path "$PACKAGE" resolve
swift build --package-path "$PACKAGE"
env -u RUN_MODEL_TESTS swift test --package-path "$PACKAGE"
swift build \
  --package-path "$PACKAGE" \
  --product MacAmbientJevProcessRecording
python3 "$ROOT/scripts/verify_cli_inputs.py" \
  "$(swift build --package-path "$PACKAGE" --show-bin-path)/MacAmbientJevProcessRecording"
swift build \
  --package-path "$PACKAGE" \
  --product MacAmbientJevEvaluateSession

for tool in "$ROOT"/tools/*.swift; do
  swiftc -typecheck "$tool"
done

if [[ "${RUN_MODEL_TESTS:-0}" == "1" ]]; then
  MODEL_TESTS="$(swift test --package-path "$PACKAGE" list)"
  if ! grep -Fq "ASRIntegrationTests" <<< "$MODEL_TESTS"; then
    echo "No ASR integration smoke tests were discovered." >&2
    exit 1
  fi

  BIN_DIR="$(swift build --package-path "$PACKAGE" --show-bin-path)"
  TEST_BUNDLE="$BIN_DIR/MacAmbientJevRuntimeTests.xctest"
  if [[ ! -d "$TEST_BUNDLE" ]]; then
    echo "Runtime test bundle was not built: $TEST_BUNDLE" >&2
    exit 1
  fi

  DYLD_FRAMEWORK_PATH="$BIN_DIR" xcrun xctest "$TEST_BUNDLE"
fi

bash "$ROOT/scripts/build_app.sh"

APP_MLX_METALLIB="$ROOT/.build/MacAmbientJev.app/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
if [[ ! -r "$APP_MLX_METALLIB" ]]; then
  echo "Built app is missing the MLX Metal shader library: $APP_MLX_METALLIB" >&2
  exit 1
fi

SIGNED_ENTITLEMENTS="$(mktemp)"
trap 'rm -f "$SIGNED_ENTITLEMENTS"' EXIT
codesign -d --entitlements - --xml "$ROOT/.build/MacAmbientJev.app" > "$SIGNED_ENTITLEMENTS" 2>/dev/null
for entitlement in \
  com.apple.security.files.user-selected.read-write \
  com.apple.security.files.bookmarks.app-scope; do
  test "$(/usr/libexec/PlistBuddy -c "Print :$entitlement" "$SIGNED_ENTITLEMENTS")" = "true"
done

echo "V1 verification passed"
