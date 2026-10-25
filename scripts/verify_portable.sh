#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE="$ROOT/app/MacAmbientJev"

FULL_MODEL=0
if [[ $# -eq 1 && "$1" == "--full-model" ]]; then
  FULL_MODEL=1
elif [[ $# -ne 0 ]]; then
  echo "usage: verify_portable.sh [--full-model]" >&2
  exit 2
fi

new_test_event_path() {
  printf '%s/.build/test-events/linux-%s.jsonl\n' \
    "$ROOT" \
    "$(python3 -c 'import uuid; print(uuid.uuid4())')"
}

python3 -B "$ROOT/scripts/test_test_time_limits.py"
python3 -B "$ROOT/scripts/check_test_time_limits.py"
python3 -B "$ROOT/scripts/test_report_test_events.py"
python3 -B "$ROOT/scripts/test_run_swift_tests.py"

# Runs one gated numerical suite with RUN_MODEL_TESTS=1, prints the executed and skipped
# test names, and fails when the suite executed no test.
run_model_suite() {
  local name="$1" filter="$2" log executed event_path
  log="$(mktemp)"
  event_path="$(new_test_event_path)"
  printf '==> model suite: %s (filter: %s)\n' "$name" "$filter"
  printf 'Swift test event stream: %s\n' "$event_path"
  env RUN_MODEL_TESTS=1 python3 -B "$ROOT/scripts/run_swift_tests.py" \
    --package-path "$PACKAGE" \
    --filter "$filter" \
    --event-stream-output-path "$event_path" 2>&1 | tee "$log"
  executed="$(grep -E 'Test .* passed after' "$log" | grep -v 'Test run' || true)"
  if [ -z "$executed" ]; then
    echo "error: model suite $name executed no test" >&2
    exit 1
  fi
  printf 'executed tests in %s (%s):\n%s\n' "$name" "$(printf '%s\n' "$executed" | wc -l | tr -d ' ')" "$executed"
  printf 'skipped tests in %s:\n%s\n' "$name" "$(grep -E 'Test .* skipped' "$log" || echo '(none)')"
  rm -f "$log"
}

run_full_model() {
  local models_directory qwen_model diarization bin_path
  models_directory="$ROOT/.build/qwen3-asr-models"
  mkdir -p "$models_directory"
  qwen_model="$(python3 "$ROOT/scripts/fetch_qwen3_asr_model.py" 0.6b "$models_directory")"
  export QWEN3_ASR_ONNX_MODEL_DIRECTORY="$qwen_model"
  export QWEN3_ASR_ONNX_MODEL_SIZE=0.6b
  printf 'Qwen3-ASR 0.6B model: %s\n' "$QWEN3_ASR_ONNX_MODEL_DIRECTORY"
  diarization="$(python3 "$ROOT/scripts/fetch_community1_diarization.py")"
  export MAC_AMBIENT_JEV_DIARIZATION_ONNX_MODEL_DIRECTORY="$diarization"
  printf 'Community-1 diarization model: %s\n' "$MAC_AMBIENT_JEV_DIARIZATION_ONNX_MODEL_DIRECTORY"

  run_model_suite "Silero VAD" 'SileroVADParityTests'
  run_model_suite "Qwen3-ASR" 'ONNXQwen3ASRModelTests|Qwen3ASRTokenReferenceTests'
  run_model_suite "Community-1 diarization" 'Community1ONNXStageTests|Community1ONNXEndToEndTests'
  run_model_suite "clause tagger" 'ONNXClauseTaggerTests'

  swift build --package-path "$PACKAGE" -c release --product MacAmbientJevProcessRecording
  swift build --package-path "$PACKAGE" -c release --product MacAmbientJevEvaluateASR
  swift build --package-path "$PACKAGE" -c release --product MacAmbientJevEngineHarness
  bin_path="$(swift build --package-path "$PACKAGE" -c release --show-bin-path)"
  fixture="$PACKAGE/Tests/MacAmbientJevPortableRuntimeTests/Resources/qwen3_asr_voicevox_long.wav"
  python3 "$ROOT/tools/linux-audio/process_recording_acceptance.py" \
    --executable "$bin_path/MacAmbientJevProcessRecording" \
    --evaluator "$bin_path/MacAmbientJevEvaluateASR" \
    --fixture "$fixture"
  python3 -B "$ROOT/scripts/engine_acceptance.py" full-model \
    --executable "$bin_path/MacAmbientJevEngineHarness" \
    --process-recording "$bin_path/MacAmbientJevProcessRecording" \
    --fixture "$fixture" \
    --threads 2
  echo "Portable full-model verification passed"
}

python3 "$ROOT/scripts/fetch_onnxruntime.py"
model="$(python3 "$ROOT/scripts/fetch_silero_vad.py")"
export MAC_AMBIENT_JEV_SILERO_MODEL="$model"
printf 'Silero VAD model: %s\n' "$MAC_AMBIENT_JEV_SILERO_MODEL"
tokenizer="$(python3 "$ROOT/scripts/fetch_qwen3_asr_tokenizer.py")"
export MAC_AMBIENT_JEV_QWEN3_TOKENIZER="$tokenizer"
printf 'Qwen3-ASR tokenizer: %s\n' "$MAC_AMBIENT_JEV_QWEN3_TOKENIZER"
clause_tagger="$(python3 "$ROOT/scripts/fetch_clause_tagger.py" --format onnx)"
export MAC_AMBIENT_JEV_CLAUSE_TAGGER_MODEL_DIRECTORY="$clause_tagger"
printf 'Clause tagger model: %s\n' "$MAC_AMBIENT_JEV_CLAUSE_TAGGER_MODEL_DIRECTORY"
cd "$ROOT"
if [ "$FULL_MODEL" = 1 ]; then
  run_full_model
  exit 0
fi
python3 -B scripts/test_fetch_silero_vad.py
python3 -B scripts/test_fetch_community1_diarization.py
python3 -B scripts/test_fetch_clause_tagger.py
python3 -B scripts/test_fetch_qwen3_asr_tokenizer.py
python3 -B scripts/test_fetch_qwen3_asr_model.py
python3 -B scripts/test_pinned_download.py
python3 -B scripts/test_generate_silero_reference.py
python3 -B scripts/test_generate_qwen3_asr_token_reference.py
python3 -B scripts/test_portable_core.py
python3 -B scripts/check_portable_core.py

swift package --package-path "$PACKAGE" dump-package >/dev/null
swift build --package-path "$PACKAGE"
EVENT_PATH="$(new_test_event_path)"
printf 'Swift test event stream: %s\n' "$EVENT_PATH"
python3 -B "$ROOT/scripts/run_swift_tests.py" \
  --package-path "$PACKAGE" \
  --event-stream-output-path "$EVENT_PATH"

echo "Portable EngineProtocol, EngineHost, PortableRuntime, Core, Pipeline, and ONNX build/test verification passed"
