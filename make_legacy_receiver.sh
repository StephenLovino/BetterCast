#!/bin/bash
set -e
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
VOL_NAME="Install BetterCast Receiver"

echo "============================================"
echo "  Building BetterCast Receiver (universal, macOS 10.15+)"
echo "============================================"
( cd LegacyMacReceiver && swift build -c release --arch arm64 --arch x86_64 )
# Xcode 27's SwiftPM moved universal products from .build/apple/... to .build/out/...
# (same relocation make_app.sh already handles). Probe both, and refuse to package
# anything if neither exists — before this check, a failed copy fell through silently
# and the DMG shipped whatever stale binary was still lying at the old path.
BIN="LegacyMacReceiver/.build/apple/Products/Release/LegacyMacReceiver"
[ -f "$BIN" ] || BIN="LegacyMacReceiver/.build/out/Products/Release/LegacyMacReceiver"
if [ ! -f "$BIN" ]; then
    echo "ERROR: built binary not found in .build/apple or .build/out — refusing to package a stale app" >&2
    exit 1
fi

# Clean old artifacts
rm -rf "$APP_NAME" "$DMG_NAME" "$DMG_STAGING"

# Assemble the .app bundle
mkdir -p "$APP_NAME/Contents/MacOS" "$APP_NAME/Contents/Resources"
cp "$BIN" "$APP_NAME/Contents/MacOS/LegacyMacReceiver"
cp "LegacyMacReceiver/Info.plist" "$APP_NAME/Contents/Info.plist"
cp "assets/branding/BetterCastIcon.icns" "$APP_NAME/Contents/Resources/AppIcon.icns"

# Localizations (shared receiver status strings resolve via Bundle.main)
for lproj in localization/*.lproj; do
    cp -R "$lproj" "$APP_NAME/Contents/Resources/"
done

# Sign with hardened runtime (required for notarization)
codesign --force --options runtime --sign "$SIGN_IDENTITY" "$APP_NAME"
codesign --verify --strict --verbose=2 "$APP_NAME"

# Package a branded DMG (cloud background + drag-to-Applications), matching the main app
echo "Creating DMG..."
mkdir -p "$DMG_STAGING"
cp -R "$APP_NAME" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"
mkdir -p "$DMG_STAGING/.background"
cp "assets/branding/dmg_background.png" "$DMG_STAGING/.background/dmg_background.png"

# Detach any stale volumes from prior runs so the AppleScript target is unambiguous
for stale in "/Volumes/$VOL_NAME" "/Volumes/$VOL_NAME 1" "/Volumes/$VOL_NAME 2"; do
    [ -d "$stale" ] && hdiutil detach "$stale" -force >/dev/null 2>&1 || true
done

# Writable DMG first so Finder can apply the layout, then convert to compressed read-only
TEMP_DMG="BetterCast-Receiver.tmp.dmg"
rm -f "$TEMP_DMG"
hdiutil create -volname "$VOL_NAME" -srcfolder "$DMG_STAGING" -fs HFS+ -format UDRW -ov "$TEMP_DMG" >/dev/null
ATTACH_OUTPUT=$(hdiutil attach "$TEMP_DMG" -nobrowse -noautoopen -readwrite)
MOUNT_DEV=$(echo "$ATTACH_OUTPUT" | grep "Apple_HFS" | awk '{print $1}')
if [ -z "$MOUNT_DEV" ]; then echo "Failed to mount $TEMP_DMG"; exit 1; fi

# Same layout as the main app: 600x400 window, app left (160,200), Applications right (440,200), 128px icons
osascript <<EOF
tell application "Finder"
    tell disk "$VOL_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {400, 100, 1000, 500}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 128
        set background picture of theViewOptions to file ".background:dmg_background.png"
        set position of item "$APP_NAME" of container window to {160, 200}
        set position of item "Applications" of container window to {440, 200}
        update without registering applications
        delay 1
        close
    end tell
end tell
EOF

sync; sleep 2
hdiutil detach "$MOUNT_DEV" >/dev/null 2>&1 || hdiutil detach "$MOUNT_DEV" -force >/dev/null 2>&1 || true

rm -f "$DMG_NAME"
hdiutil convert "$TEMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_NAME" >/dev/null
rm -f "$TEMP_DMG"
rm -rf "$DMG_STAGING"

# Sign the DMG itself (so Gatekeeper accepts the disk image, not just the app inside)
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
