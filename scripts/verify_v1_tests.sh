#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE="$ROOT/app/MacAmbientJev"

python3 "$ROOT/scripts/test_doc_references.py"
python3 "$ROOT/scripts/check_doc_references.py" "$ROOT"
python3 "$ROOT/scripts/test_session_artifacts.py"
python3 "$ROOT/scripts/test_japanese_numeral_exclusions.py"

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
swift build --package-path "$PACKAGE" --build-tests
env -u RUN_MODEL_TESTS swift test --package-path "$PACKAGE" --skip-build
swift build \
  --package-path "$PACKAGE" \
  --product MacAmbientJevProcessRecording
python3 "$ROOT/scripts/verify_cli_inputs.py" \
  "$(swift build --package-path "$PACKAGE" --show-bin-path)/MacAmbientJevProcessRecording"
swift build \
  --package-path "$PACKAGE" \
  --product MacAmbientJevEvaluateSession

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

echo "V1 tests verification passed"
