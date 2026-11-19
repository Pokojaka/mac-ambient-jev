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

for artifact in ClauseTagger.mlpackage tokenizer.json LICENSE.md; do
  if [[ ! -e "$APP_CONTENTS/Resources/clause-tagger/$artifact" ]]; then
    echo "Built app is missing the clause tagger model file: $artifact" >&2
    exit 1
  fi
done
if ! cmp -s "$ROOT/app/MacAmbientJev/Sources/MacAmbientJevRuntime/Resources/fluid_vad_model.json" "$APP_CONTENTS/Resources/MacAmbientJev_MacAmbientJevRuntime.bundle/Contents/Resources/Resources/fluid_vad_model.json"; then
  echo "Built app is missing or has a different fluid VAD model config." >&2
  exit 1
fi
if ! cmp -s "$ROOT/app/MacAmbientJev/Sources/MacAmbientJevHaasASR/Resources/haas_asr_model.json" "$APP_CONTENTS/Resources/MacAmbientJev_MacAmbientJevHaasASR.bundle/Contents/Resources/Resources/haas_asr_model.json"; then
  echo "Built app is missing or has a different Haas ASR model config." >&2
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
