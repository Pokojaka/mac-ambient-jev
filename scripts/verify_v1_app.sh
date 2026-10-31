#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

bash "$ROOT/scripts/build_app.sh"

APP_CONTENTS="$ROOT/.build/MacAmbientJev.app/Contents"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$APP_CONTENTS/Info.plist")" = "AppIcon.icns"
ICONSET="$ROOT/.build/VerifiedAppIcon.iconset"
rm -rf "$ICONSET"
iconutil -c iconset "$APP_CONTENTS/Resources/AppIcon.icns" -o "$ICONSET"
test -r "$ICONSET/icon_16x16.png"
test -r "$ICONSET/icon_512x512@2x.png"
rm -rf "$ICONSET"

APP_MLX_METALLIB="$ROOT/.build/MacAmbientJev.app/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
if [[ ! -r "$APP_MLX_METALLIB" ]]; then
  echo "Built app is missing the MLX Metal shader library: $APP_MLX_METALLIB" >&2
  exit 1
fi

for artifact in ClauseTagger.mlpackage tokenizer.json LICENSE.md; do
  if [[ ! -e "$APP_CONTENTS/Resources/clause-tagger/$artifact" ]]; then
    echo "Built app is missing the clause tagger model file: $artifact" >&2
    exit 1
  fi
done
# Bundle.module finds MacAmbientJevRuntime's resources in Contents/Resources of the app; the model
# manifest the app loads at launch must be there and equal to the source.
APP_MODEL_MANIFEST="$APP_CONTENTS/Resources/MacAmbientJev_MacAmbientJevRuntime.bundle/Contents/Resources/Resources/mac_models.json"
SOURCE_MODEL_MANIFEST="$ROOT/app/MacAmbientJev/Sources/MacAmbientJevRuntime/Resources/mac_models.json"
if ! cmp -s "$APP_MODEL_MANIFEST" "$SOURCE_MODEL_MANIFEST"; then
  echo "Built app is missing the pinned model manifest or it differs from the source: $APP_MODEL_MANIFEST" >&2
  exit 1
fi
codesign --verify --deep "$ROOT/.build/MacAmbientJev.app"

SIGNED_ENTITLEMENTS="$(mktemp)"
trap 'rm -f "$SIGNED_ENTITLEMENTS"' EXIT
codesign -d --entitlements - --xml "$ROOT/.build/MacAmbientJev.app" > "$SIGNED_ENTITLEMENTS" 2>/dev/null
for entitlement in \
  com.apple.security.files.user-selected.read-write \
  com.apple.security.files.bookmarks.app-scope; do
  test "$(/usr/libexec/PlistBuddy -c "Print :$entitlement" "$SIGNED_ENTITLEMENTS")" = "true"
done

echo "V1 app verification passed"
