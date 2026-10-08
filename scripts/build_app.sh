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
ICON_SOURCE="$PACKAGE/Assets/AppIcon.png"

if [[ ! -r "$ICON_SOURCE" ]]; then
  echo "App icon source is missing: $ICON_SOURCE" >&2
  exit 1
fi

swift build --package-path "$PACKAGE" --build-system swiftbuild --arch arm64 -c release --product MacAmbientJev

BIN_DIR="$(swift build --package-path "$PACKAGE" --build-system swiftbuild --arch arm64 -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"
cp "$BIN_DIR/MacAmbientJev" "$MACOS/MacAmbientJev"

ICONSET="$RESOURCES/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$ICON_SOURCE" \
    --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  retina_size=$((size * 2))
  sips -z "$retina_size" "$retina_size" "$ICON_SOURCE" \
    --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$RESOURCES/AppIcon.icns"
rm -rf "$ICONSET"

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

SIGNING_IDENTITY="MacAmbientJev Local Signing"
if ! security find-certificate -c "$SIGNING_IDENTITY" >/dev/null 2>&1; then
  echo "Code signing certificate \"$SIGNING_IDENTITY\" is not in the keychain. Create it as described in README.md." >&2
  exit 1
fi
codesign --force --sign "$SIGNING_IDENTITY" --entitlements "$PACKAGE/Entitlements/MacAmbientJev.entitlements" "$APP"

echo "$APP"
