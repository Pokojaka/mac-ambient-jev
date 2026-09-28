#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "${1:-}" == "--print-info-plist" && $# -eq 1 ]]; then
  exec bash "$ROOT/scripts/app_info_plist.sh"
fi

PACKAGE="$ROOT/app/MacAmbientJev"
APP="$ROOT/.build/MacAmbientJev.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

swift build   --package-path "$PACKAGE"   -c release   --product MacAmbientJev

BIN_DIR="$(swift build   --package-path "$PACKAGE"   -c release   --show-bin-path)"

rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"
cp "$BIN_DIR/MacAmbientJev" "$MACOS/MacAmbientJev"

MLX_BUNDLE="$BIN_DIR/mlx-swift_Cmlx.bundle"
MLX_METALLIB="$MLX_BUNDLE/Contents/Resources/default.metallib"
if [[ ! -r "$MLX_METALLIB" ]]; then
  echo "SwiftPM MLX shader bundle is missing: $MLX_METALLIB" >&2
  exit 1
fi

shopt -s nullglob
RESOURCE_BUNDLES=("$BIN_DIR"/*.bundle)
if (( ${#RESOURCE_BUNDLES[@]} == 0 )); then
  echo "No SwiftPM resource bundles found in $BIN_DIR" >&2
  exit 1
fi

for bundle in "${RESOURCE_BUNDLES[@]}"; do
  cp -R "$bundle" "$RESOURCES/"
done

bash "$ROOT/scripts/app_info_plist.sh" > "$CONTENTS/Info.plist"

if command -v codesign >/dev/null 2>&1; then
  codesign     --force     --sign -     --entitlements "$PACKAGE/Entitlements/MacAmbientJev.entitlements"     "$APP"
fi

echo "$APP"
