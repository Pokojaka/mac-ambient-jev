#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -lt 3 || "$1" != "--sessions-root" || -z "$2" ]]; then
  printf 'usage: %s --sessions-root DIRECTORY [--sample-rate HZ] [--channels COUNT] [--match-default-input] <existing-audio-file>\n' "$0" >&2
  exit 2
fi

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

exec swift run \
  --disable-sandbox \
  --package-path "$repo_root/app/MacAmbientJev" \
  MacAmbientJevMeasureLiveLatency \
  "$@"
