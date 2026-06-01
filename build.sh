#!/usr/bin/env bash
# build.sh — compile MB Clip Editor into a .app bundle.
#
# Usage:
#   ./build.sh                      # dev build: compile only, ad-hoc sign, needs Homebrew tools at runtime
#   ./build.sh --bundle             # self-contained: also bundle ffmpeg/whisper + model into the app
#   SIGN_ID="Developer ID Application: Name (TEAMID)" ./build.sh --bundle   # sign for notarization
#   APP_OUT=/path ./build.sh        # choose output folder (default ./build)
#
# Build needs: Xcode CLT (swiftc), macOS 15+ SDK. For --bundle: dylibbundler,
# plus ffmpeg/ffprobe/whisper-cli + the model present (see scripts/fetch-model.sh).

set -euo pipefail
cd "$(dirname "$0")"

BUNDLE=0; [ "${1:-}" = "--bundle" ] && BUNDLE=1

APP_NAME="Clip Editor"
EXE="MBClipEditor"
BUNDLE_ID="com.mblocal.clipeditor1"
OUT_DIR="${APP_OUT:-$(pwd)/build}"
APP="$OUT_DIR/$APP_NAME.app"
SIGN_ID="${SIGN_ID:--}"                 # default ad-hoc
ENT="$(pwd)/Resources/entitlements.plist"

echo "==> Building $APP_NAME.app  (bundle=$BUNDLE, sign=$SIGN_ID)"
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

if [ "$BUNDLE" = 1 ]; then
  echo "==> bundling dependencies (self-contained)"
  ./scripts/bundle-deps.sh "$APP"
fi

echo "==> codesign"
# Sign inside-out: bundled dylibs + helper tools first, then the app.
RUNTIME=""; [ "$SIGN_ID" != "-" ] && RUNTIME="--options runtime"
if [ "$BUNDLE" = 1 ]; then
  # Sign inner-most first: dylibs/plugins, then helper executables.
  find "$APP/Contents/Frameworks" \( -name "*.dylib" -o -name "*.so" \) -exec \
    codesign --force $RUNTIME --timestamp -s "$SIGN_ID" {} \; 2>/dev/null || true
  find "$APP/Contents/Helpers" -name "*.so" -exec \
    codesign --force $RUNTIME --timestamp -s "$SIGN_ID" {} \; 2>/dev/null || true
  for t in ffmpeg ffprobe whisper-cli; do
    codesign --force $RUNTIME --timestamp -s "$SIGN_ID" "$APP/Contents/Helpers/$t"
  done
fi
codesign --force $RUNTIME --timestamp --entitlements "$ENT" -s "$SIGN_ID" "$APP/Contents/MacOS/$EXE"
codesign --force $RUNTIME --timestamp --entitlements "$ENT" -s "$SIGN_ID" "$APP"

echo "==> Done: $APP"
du -sh "$APP" 2>/dev/null | awk '{print "    size: "$1}'
codesign -dv "$APP" 2>&1 | grep -iE "Authority|Signature" || true
echo "    (For distribution: SIGN_ID=<Developer ID> ./build.sh --bundle, then scripts/notarize.sh)"
