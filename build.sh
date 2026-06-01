#!/usr/bin/env bash
# build.sh — compile SimpleClips into a .app bundle.
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

APP_NAME="SimpleClips"
EXE="SimpleClips"
BUNDLE_ID="com.mblocal.clipeditor1"   # unchanged on purpose: keeps the existing TCC permission grant
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
  <key>CFBundleName</key><string>SimpleClips</string>
  <key>CFBundleDisplayName</key><string>SimpleClips</string>
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

# Hardened runtime + entitlements + secure timestamp ONLY for notarization
# (Developer ID, or NOTARIZE=1). Those need Apple's network timestamp service and
# would FAIL with a local self-signed/ad-hoc cert — which silently leaves an
# ad-hoc signature whose requirement changes every build and breaks TCC grants.
HARDEN=0
case "$SIGN_ID" in "Developer ID"*) HARDEN=1;; esac
[ "${NOTARIZE:-0}" = 1 ] && HARDEN=1

if [ "$HARDEN" = 1 ]; then
  echo "==> codesign (hardened runtime, for notarization)"
  if [ "$BUNDLE" = 1 ]; then
    find "$APP/Contents/Frameworks" \( -name "*.dylib" -o -name "*.so" \) -exec \
      codesign --force --options runtime --timestamp -s "$SIGN_ID" {} \; 2>/dev/null || true
    find "$APP/Contents/Helpers" -name "*.so" -exec \
      codesign --force --options runtime --timestamp -s "$SIGN_ID" {} \; 2>/dev/null || true
    for t in ffmpeg ffprobe whisper-cli; do
      codesign --force --options runtime --timestamp -s "$SIGN_ID" "$APP/Contents/Helpers/$t"
    done
  fi
  codesign --force --options runtime --timestamp --entitlements "$ENT" -s "$SIGN_ID" "$APP/Contents/MacOS/$EXE"
  codesign --force --options runtime --timestamp --entitlements "$ENT" -s "$SIGN_ID" "$APP"
else
  echo "==> codesign (local: plain deep sign — no timestamp/runtime)"
  codesign --force --deep -s "$SIGN_ID" "$APP"
fi

echo "==> Done: $APP"
du -sh "$APP" 2>/dev/null | awk '{print "    size: "$1}'
codesign -dv "$APP" 2>&1 | grep -iE "Authority|Signature" || true
echo "    (For distribution: SIGN_ID=<Developer ID> ./build.sh --bundle, then scripts/notarize.sh)"
