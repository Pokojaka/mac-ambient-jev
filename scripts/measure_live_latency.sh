#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -lt 3 || "$1" != "--sessions-root" || -z "$2" ]]; then
  printf 'usage: %s --sessions-root DIRECTORY [--sample-rate HZ] [--channels COUNT] [--match-default-input] <existing-audio-file>\n' "$0" >&2
  exit 2
fi

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
cache_root="/private/tmp/mac-ambient-jev-swift-cache"
config_root="/private/tmp/mac-ambient-jev-swift-config"
module_cache="/private/tmp/mac-ambient-jev-clang-cache"
mkdir -p "$cache_root" "$config_root" "$module_cache"

export SWIFTPM_MODULECACHE_OVERRIDE="$module_cache"
export CLANG_MODULE_CACHE_PATH="$module_cache"

exec swift run \
  --disable-sandbox \
  --cache-path "$cache_root" \
  --config-path "$config_root" \
  --package-path "$repo_root/app/MacAmbientJev" \
  MacAmbientJevMeasureLiveLatency \
  "$@"
