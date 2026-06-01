#!/usr/bin/env bash
# build.sh — compile MB Clip Editor into a .app bundle.
#
# Usage:
#   ./build.sh                 # ad-hoc signed, output to ./build/Clip Editor.app
#   SIGN_ID="MB Local Codesign" ./build.sh     # sign with a named identity
#   APP_OUT="/Applications" ./build.sh         # choose output folder
#
# Requirements to BUILD:  Xcode command line tools (swiftc), macOS 15+ SDK.
# Requirements to RUN:    ffmpeg + ffprobe + whisper-cli on PATH (Homebrew),
#                         and the Whisper model (see scripts/fetch-model.sh).
#                         See README.md — the app is NOT yet self-contained.

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Clip Editor"
EXE="MBClipEditor"
BUNDLE_ID="com.mblocal.clipeditor1"
OUT_DIR="${APP_OUT:-$(pwd)/build}"
APP="$OUT_DIR/$APP_NAME.app"
SIGN_ID="${SIGN_ID:--}"   # default: ad-hoc

echo "==> Building $APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>MB Clip Editor</string>
  <key>CFBundleDisplayName</key><string>MB Clip Editor</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>$EXE</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSMicrophoneUsageDescription</key><string>Records your microphone when you enable Mic for a screen recording.</string>
</dict>
</plist>
PLIST

echo "==> swiftc"
swiftc -O -parse-as-library -o "$APP/Contents/MacOS/$EXE" Sources/ClipEditor.swift \
  -framework SwiftUI -framework AppKit -framework AVKit -framework AVFoundation -framework ScreenCaptureKit

echo "==> codesign ($SIGN_ID)"
codesign --force --deep -s "$SIGN_ID" "$APP"

echo "==> Done: $APP"
codesign -dv "$APP" 2>&1 | grep -iE "Authority|Signature" || true
