#!/bin/bash
# Build, sign, and notarize the standalone "BetterCast Receiver" app for older macOS
# (10.15 Catalina / 11 Big Sur / 12 Monterey) — see LegacyMacReceiver/ and issues #33, #34.
# Receiver-only, universal (Intel + Apple Silicon). Set APPLE_ID + APP_PASSWORD to notarize.
set -e

SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: STEPHEN JAN LOVINO (TQ8F92XYBL)}"
APPLE_ID="${APPLE_ID:-}"
TEAM_ID="TQ8F92XYBL"
APP_NAME="BetterCast Receiver.app"
DMG_NAME="BetterCast-Receiver.dmg"
DMG_STAGING="dmg_receiver_staging"

echo "============================================"
echo "  Building BetterCast Receiver (universal, macOS 10.15+)"
echo "============================================"
( cd LegacyMacReceiver && swift build -c release --arch arm64 --arch x86_64 )
BIN="LegacyMacReceiver/.build/apple/Products/Release/LegacyMacReceiver"

# Clean old artifacts
rm -rf "$APP_NAME" "$DMG_NAME" "$DMG_STAGING"

# Assemble the .app bundle
mkdir -p "$APP_NAME/Contents/MacOS" "$APP_NAME/Contents/Resources"
cp "$BIN" "$APP_NAME/Contents/MacOS/LegacyMacReceiver"
cp "LegacyMacReceiver/Info.plist" "$APP_NAME/Contents/Info.plist"
cp "assets/branding/BetterCastIcon.icns" "$APP_NAME/Contents/Resources/AppIcon.icns"

# Sign with hardened runtime (required for notarization)
codesign --force --options runtime --sign "$SIGN_IDENTITY" "$APP_NAME"
codesign --verify --strict --verbose=2 "$APP_NAME"

# Package a simple drag-to-Applications DMG
echo "Creating DMG..."
mkdir -p "$DMG_STAGING"
cp -R "$APP_NAME" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"
hdiutil create -volname "BetterCast Receiver" -srcfolder "$DMG_STAGING" -ov -format UDZO "$DMG_NAME" >/dev/null
rm -rf "$DMG_STAGING"

# Sign the DMG too (so Gatekeeper accepts the disk image itself, not just the app inside)
codesign --force --sign "$SIGN_IDENTITY" "$DMG_NAME"

# Notarize (optional — needs APPLE_ID + APP_PASSWORD)
if [ -n "$APPLE_ID" ]; then
    echo "Notarizing $DMG_NAME..."
    xcrun notarytool submit "$DMG_NAME" \
        --apple-id "$APPLE_ID" \
        --team-id "$TEAM_ID" \
        --password "$APP_PASSWORD" \
        --wait
    echo "Stapling notarization ticket..."
    xcrun stapler staple "$DMG_NAME"
    xcrun stapler staple "$APP_NAME"
else
    echo "Skipping notarization (set APPLE_ID and APP_PASSWORD to enable)."
fi

echo "============================================"
echo "  Done: $DMG_NAME"
echo "============================================"
