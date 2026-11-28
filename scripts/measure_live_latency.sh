#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -lt 5 || "$1" != "--sessions-root" || -z "$2" ]]; then
  printf 'usage: %s --sessions-root DIRECTORY --memory-output PATH [--sample-rate HZ] [--channels COUNT] [--match-default-input] <existing-audio-file>\n' "$0" >&2
  exit 2
fi

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

python3 -B "$repo_root/scripts/fetch_onnxruntime.py"
exec swift run \
  --disable-sandbox \
  -c release \
  --package-path "$repo_root/app/MacAmbientJev" \
  MacAmbientJevMeasureLiveLatency \
  "$@"
