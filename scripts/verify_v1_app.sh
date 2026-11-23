#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

bash "$ROOT/scripts/build_app.sh"

APP_CONTENTS="$ROOT/.build/MacAmbientJev.app/Contents"
SDK_ROOT="$ROOT/.build/onnxruntime/1.31.0/osx-arm64"
DYLIB="$APP_CONTENTS/Frameworks/libonnxruntime.1.dylib"
EXECUTABLE="$APP_CONTENTS/MacOS/MacAmbientJev"
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
if [[ ! -f "$DYLIB" ]]; then
  echo "Built app is missing ONNX Runtime dylib: $DYLIB" >&2
  exit 1
fi
DYLIB_ID_OUTPUT="$(otool -D "$DYLIB")"
if ! awk 'NR == 1 { next } NF { if ($0 != "@rpath/libonnxruntime.1.dylib") exit 1; count++ } END { if (count != 1) exit 1 }' <<< "$DYLIB_ID_OUTPUT"; then
  echo "Bundled ONNX Runtime dylib has an unexpected install ID:" >&2
  echo "$DYLIB_ID_OUTPUT" >&2
  exit 1
fi
for artifact in LICENSE ThirdPartyNotices.txt; do
  bundled="$APP_CONTENTS/Resources/onnxruntime/$artifact"
  if [[ ! -f "$bundled" ]]; then
    echo "Built app is missing ONNX Runtime resource: $bundled" >&2
    exit 1
  fi
  if ! cmp -s "$SDK_ROOT/$artifact" "$bundled"; then
    echo "Built app has a different ONNX Runtime resource: $bundled" >&2
    exit 1
  fi
done
RPATHS="$(otool -l "$EXECUTABLE" | awk '
  $1 == "cmd" { in_rpath = ($2 == "LC_RPATH"); next }
  in_rpath && $1 == "path" {
    sub(/^[[:space:]]*path[[:space:]]+/, "")
    sub(/[[:space:]]+\(offset [0-9]+\)$/, "")
    print
    in_rpath = 0
  }
')"
FRAMEWORK_RPATH_FOUND=0
while IFS= read -r rpath; do
  if [[ "$rpath" == "@executable_path/../Frameworks" ]]; then
    FRAMEWORK_RPATH_FOUND=1
  fi
  if [[ "${rpath:0:${#ROOT}}" == "$ROOT" ]]; then
    echo "App contains repository-local runtime path: $rpath" >&2
    exit 1
  fi
done <<< "$RPATHS"
if [[ "$FRAMEWORK_RPATH_FOUND" -ne 1 ]]; then
  echo "App is missing rpath @executable_path/../Frameworks" >&2
  exit 1
fi
codesign --verify --strict "$DYLIB"
codesign --verify --deep --strict "$ROOT/.build/MacAmbientJev.app"

SIGNED_ENTITLEMENTS="$(mktemp)"
trap 'rm -f "$SIGNED_ENTITLEMENTS"' EXIT
codesign -d --entitlements - --xml "$ROOT/.build/MacAmbientJev.app" > "$SIGNED_ENTITLEMENTS" 2>/dev/null
for entitlement in \
  com.apple.security.files.user-selected.read-write \
  com.apple.security.files.bookmarks.app-scope; do
  test "$(/usr/libexec/PlistBuddy -c "Print :$entitlement" "$SIGNED_ENTITLEMENTS")" = "true"
done

echo "V1 app verification passed"
