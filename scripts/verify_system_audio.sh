#!/bin/bash
set -euo pipefail

if (( $# != 3 )); then
  echo "Usage: $0 <WAV file> <duration seconds> <sessions root>" >&2
  exit 2
fi
WAV="$(realpath "$1")"
DURATION="$2"
SESSIONS_ROOT="$3"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE="$ROOT/app/MacAmbientJev"
SUMMARY="$(mktemp)"
ERR="$(mktemp)"
cleanup() { rm -f "$SUMMARY" "$ERR"; }
trap cleanup EXIT

# Build first; never overlap SwiftPM commands or the live capture.
swift build --package-path "$PACKAGE" --product MacAmbientJevCaptureSystemAudio --disable-automatic-resolution
BIN_DIR="$(swift build --package-path "$PACKAGE" --show-bin-path --disable-automatic-resolution)"
"$BIN_DIR/MacAmbientJevCaptureSystemAudio" --duration "$DURATION" --sessions-root "$SESSIONS_ROOT" > "$SUMMARY" 2> "$ERR" &
CAPTURE_PID=$!
sleep 1.5
afplay "$WAV"
wait "$CAPTURE_PID" || { cat "$ERR" >&2; cat "$SUMMARY" >&2; exit 1; }

python3 - "$SUMMARY" "$WAV" "$DURATION" <<'PY'
import array
import json
import math
import pathlib
import sys
import wave

summary = json.loads(pathlib.Path(sys.argv[1]).read_text())
with wave.open(sys.argv[2], 'rb') as wav:
    wav_seconds = wav.getnframes() / wav.getframerate()
duration = float(sys.argv[3])
rate = float(summary['sample_rate'])
frames = int(summary['frames_written'])
assert abs(frames - duration * rate) <= 0.20 * rate + 4096, (frames, duration * rate)
assert summary['dropout_count'] == 0, summary
assert not summary['errors'], summary
assert summary['sleep_assertion_held'], summary
assert duration > 1.8 and wav_seconds > 0, 'WAV needs to overlap capture after 1.5s'
processing = pathlib.Path(summary['path']) / 'audio' / 'processing'
checkpoint = json.loads((processing / 'checkpoint.json').read_text())
assert checkpoint['channelCount'] == 1, checkpoint
start = int(1.5 * rate)
end = min(frames, int((1.5 + wav_seconds) * rate))
assert end - start >= int(0.1 * rate), 'played file does not overlap capture long enough'
peak = 0.0
position = 0
for filename in checkpoint['chunkFiles']:
    samples = array.array('f')
    samples.frombytes((processing / filename).read_bytes())
    if sys.byteorder != 'little':
        samples.byteswap()
    left, right = max(0, start - position), min(len(samples), end - position)
    if right > left:
        peak = max(peak, max(abs(sample) for sample in samples[left:right]))
    position += len(samples)
assert peak > 0.001, f'no non-silent samples aligned with WAV playback: peak={peak}'
print(json.dumps({'session_id': summary['session_id'], 'frames_written': frames,
                  'sample_rate': rate, 'playback_window_peak': peak}, ensure_ascii=False))
PY
