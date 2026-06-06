#!/usr/bin/env bash
# notarize.sh — submit the (Developer ID-signed, --bundle) app to Apple's notary
# service, staple the ticket, and produce a distributable DMG/zip.
#
# Prereqs (one-time, after you enroll in the Apple Developer Program — $99/yr):
#   1) A "Developer ID Application" certificate in your login keychain.
#   2) Build a signed, bundled app:
#        SIGN_ID="Developer ID Application: Your Name (TEAMID)" ./build.sh --bundle
#   3) Store notary credentials once:
#        xcrun notarytool store-credentials MB-NOTARY \
#          --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
#      (app-specific password from appleid.apple.com)
#
# Usage:  ./scripts/notarize.sh "build/SimpleClips.app"

set -euo pipefail
APP="${1:?usage: notarize.sh <App.app>}"
PROFILE="${NOTARY_PROFILE:-MB-NOTARY}"
ZIP="${APP%.app}.zip"

echo "==> zipping for submission"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> submitting to Apple notary (this can take a few minutes)"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "==> stapling ticket to the app"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> gatekeeper assessment (should say: accepted, source=Notarized Developer ID)"
spctl -a -vv "$APP" || true

echo "==> done. Distribute the .app (zip it, or build a DMG):"
echo "    ditto -c -k --keepParent \"$APP\" \"${APP%.app}.zip\""
