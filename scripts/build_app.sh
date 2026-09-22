#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE="$ROOT/app/MacAmbientJev"
APP="$ROOT/.build/MacAmbientJev.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"

swift build   --package-path "$PACKAGE"   -c release   --product MacAmbientJev

BIN_DIR="$(swift build   --package-path "$PACKAGE"   -c release   --show-bin-path)"

rm -rf "$APP"
mkdir -p "$MACOS"
cp "$BIN_DIR/MacAmbientJev" "$MACOS/MacAmbientJev"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>ja</string>
    <key>CFBundleDisplayName</key>
    <string>Mac Ambient Jev</string>
    <key>CFBundleExecutable</key>
    <string>MacAmbientJev</string>
    <key>CFBundleIdentifier</key>
    <string>app.mac-ambient-jev</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Mac Ambient Jev</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>講義や会話を文字起こしするためにマイクを使用します</string>
</dict>
</plist>
PLIST

if command -v codesign >/dev/null 2>&1; then
  codesign     --force     --sign -     --entitlements "$PACKAGE/Entitlements/MacAmbientJev.entitlements"     "$APP"
fi

echo "$APP"
