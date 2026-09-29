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

# Validate playback before building or starting capture.
python3 -I - "$WAV" "$DURATION" <<'PY'
import math
import sys
import wave

duration = float(sys.argv[2])
assert math.isfinite(duration) and duration > 1.8, 'duration must exceed playback delay'
with wave.open(sys.argv[1], 'rb') as wav:
    assert wav.getframerate() > 0, 'invalid WAV sample rate'
    wav_seconds = wav.getnframes() / wav.getframerate()
assert min(duration, 1.5 + wav_seconds) - 1.5 >= 0.1, 'WAV must overlap capture for 0.1s'
PY

SUMMARY="$(mktemp)"
ERR="$(mktemp)"
CAPTURE_PID=""
cleanup() {
  if [[ -n "$CAPTURE_PID" ]] && kill -0 "$CAPTURE_PID" 2>/dev/null; then
    kill "$CAPTURE_PID"
    wait "$CAPTURE_PID" || :
  fi
  rm -f "$SUMMARY" "$ERR"
}
trap cleanup EXIT
# Build first; never overlap SwiftPM commands or the live capture.
swift build --package-path "$PACKAGE" --product MacAmbientJevCaptureSystemAudio --disable-automatic-resolution
BIN_DIR="$(swift build --package-path "$PACKAGE" --show-bin-path --disable-automatic-resolution)"
# TCC attributes a shell-launched tool to its terminal, which has no
# NSAudioCaptureUsageDescription, so macOS never prompts and the tap delivers
# zeros. Launching a bundle through LaunchServices makes it the responsible process.
APP="$PACKAGE/.build/MacAmbientJevCaptureSystemAudio.app"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/MacAmbientJevCaptureSystemAudio" "$APP/Contents/MacOS/"
DESCRIPTION="$(bash "$ROOT/scripts/app_info_plist.sh" | plutil -extract NSAudioCaptureUsageDescription raw -)"
plutil -create xml1 "$APP/Contents/Info.plist"
plutil -insert CFBundleIdentifier -string app.mac-ambient-jev.capture-system-audio "$APP/Contents/Info.plist"
plutil -insert CFBundleExecutable -string MacAmbientJevCaptureSystemAudio "$APP/Contents/Info.plist"
plutil -insert CFBundlePackageType -string APPL "$APP/Contents/Info.plist"
plutil -insert LSUIElement -bool true "$APP/Contents/Info.plist"
plutil -insert NSAudioCaptureUsageDescription -string "$DESCRIPTION" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null
SESSIONS_ROOT_ABS="$(mkdir -p "$SESSIONS_ROOT" && cd "$SESSIONS_ROOT" && pwd -P)"
open -W -n --stdout "$SUMMARY" --stderr "$ERR" "$APP" \
  --args --duration "$DURATION" --sessions-root "$SESSIONS_ROOT_ABS" &
CAPTURE_PID=$!
sleep 1.5
afplay "$WAV"
wait "$CAPTURE_PID" || { cat "$ERR" >&2; cat "$SUMMARY" >&2; exit 1; }
CAPTURE_PID=""
[[ -s "$SUMMARY" ]] || { cat "$ERR" >&2; echo "capture produced no summary" >&2; exit 1; }

python3 -I - "$SUMMARY" "$WAV" "$DURATION" "$SESSIONS_ROOT" <<'PY'
import array
import json
import math
import pathlib
import sys
import uuid
import wave

summary = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert isinstance(summary, dict), 'capture summary must be a JSON object'
assert summary.get('errors') == [], summary
session_id = summary['session_id']
assert isinstance(session_id, str) and str(uuid.UUID(session_id)) == session_id.lower(), summary
session = pathlib.Path(summary['path']).resolve()
expected = pathlib.Path(sys.argv[4]).resolve() / session_id
assert session == expected, (session, expected)
rate = summary['sample_rate']
frames = summary['frames_written']
assert type(rate) in (int, float) and math.isfinite(rate) and rate > 0, summary
assert type(frames) is int and frames > 0, summary
assert type(summary['dropout_count']) is int and summary['dropout_count'] == 0, summary
assert summary['sleep_assertion_held'] is True, summary
with wave.open(sys.argv[2], 'rb') as wav:
    wav_seconds = wav.getnframes() / wav.getframerate()
duration = float(sys.argv[3])
assert abs(frames - duration * rate) <= 0.20 * rate + 4096, (frames, duration * rate)
processing = session / 'audio' / 'processing'
checkpoint = json.loads((processing / 'checkpoint.json').read_text())
assert checkpoint['channelCount'] == 1, checkpoint
assert checkpoint['committedFrames'] == frames, checkpoint
assert checkpoint['sampleRate'] == rate, checkpoint
chunk_files = checkpoint['chunkFiles']
assert isinstance(chunk_files, list) and chunk_files and len(set(chunk_files)) == len(chunk_files), checkpoint
start = int(1.5 * rate)
end = min(frames, int((1.5 + wav_seconds) * rate))
assert end - start >= int(0.1 * rate), 'played file does not overlap capture long enough'
peak = 0.0
position = 0
for filename in chunk_files:
    assert isinstance(filename, str) and filename not in ('', '.', '..')
    assert pathlib.Path(filename).name == filename, filename
    chunk_path = processing / filename
    assert chunk_path.resolve().parent == processing.resolve(), filename
    with chunk_path.open('rb') as chunk:
        size = chunk.seek(0, 2)
        assert size > 0 and size % 4 == 0, (filename, size)
        count = size // 4
        left, right = max(0, start - position), min(count, end - position)
        if right > left:
            chunk.seek(left * 4)
            samples = array.array('f')
            samples.frombytes(chunk.read((right - left) * 4))
            if sys.byteorder != 'little':
                samples.byteswap()
            peak = max(peak, max((abs(sample) for sample in samples if math.isfinite(sample)), default=0.0))
        position += count
assert position == frames, (position, frames)
assert peak > 0.001, f'no non-silent samples aligned with WAV playback: peak={peak}'
print(json.dumps({'session_id': session_id, 'frames_written': frames,
                  'sample_rate': rate, 'playback_window_peak': peak}, ensure_ascii=False))
PY
