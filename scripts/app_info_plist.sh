#!/bin/bash
set -euo pipefail

cat <<'PLIST'
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
    <key>CFBundleIconFile</key>
    <string>AppIcon.icns</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Mac Ambient Jev</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.1</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>講義や会話を文字起こしするためにマイクを使用します</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>Macで再生中の講義や動画をマイクなしで文字起こしするためにシステム音声を録音します</string>
</dict>
</plist>
PLIST
