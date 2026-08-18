#!/bin/bash

# Exit on error
set -e

VERSION="v18"

# Code signing identity (Developer ID Application certificate)
# Set to "-" for ad-hoc signing (local use), or your Developer ID for distribution
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: STEPHEN JAN LOVINO (TQ8F92XYBL)}"

# Apple ID for notarization (set via environment or here)
APPLE_ID="${APPLE_ID:-}"
TEAM_ID="TQ8F92XYBL"

echo "============================================"
echo "  Building BetterCast $VERSION (Universal Binary)"
echo "============================================"
swift build -c release --arch arm64 --arch x86_64

# Define Paths
# Xcode 26 and earlier put the universal binary under .build/apple/…; Xcode 27
# moved it to .build/out/…. Accept whichever this toolchain produced.
if [ -f ".build/apple/Products/Release/BetterCastSender" ]; then
    BUILD_DIR=".build/apple/Products/Release"
elif [ -f ".build/out/Products/Release/BetterCastSender" ]; then
    BUILD_DIR=".build/out/Products/Release"
else
    echo "error: could not find the built BetterCastSender binary under .build/" >&2
    exit 1
fi
APP_NAME="BetterCast.app"
DMG_NAME="BetterCast.dmg"
DMG_STAGING="dmg_staging"

# Clean old artifacts
rm -rf "$APP_NAME" "BetterCastSender.app" "$DMG_STAGING" "$DMG_NAME"

# ============================================
# BetterCast App (unified sender + receiver)
# ============================================
echo "Creating $APP_NAME..."
mkdir -p "$APP_NAME/Contents/MacOS"
mkdir -p "$APP_NAME/Contents/Resources"
# Binary is still named BetterCastSender from the Swift package target
cp "$BUILD_DIR/BetterCastSender" "$APP_NAME/Contents/MacOS/BetterCastSender"
cp "BetterCastSender-Info.plist" "$APP_NAME/Contents/Info.plist"
cp "assets/branding/BetterCastIcon.icns" "$APP_NAME/Contents/Resources/AppIcon.icns"

# Localizations: NSLocalizedString / SwiftUI LocalizedStringKey resolve through
# Bundle.main, so shipping the .lproj folders in Contents/Resources is all it
# takes for the app to follow the system language.
for lproj in localization/*.lproj; do
    cp -R "$lproj" "$APP_NAME/Contents/Resources/"
done

# Code sign with entitlements
codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" --entitlements "BetterCastSender-Release.entitlements" "$APP_NAME"

# ============================================
# Create DMG (with custom install background)
# ============================================
echo "Creating DMG..."
mkdir -p "$DMG_STAGING"
cp -R "$APP_NAME" "$DMG_STAGING/"

# Create a symlink to /Applications for drag-to-install
ln -s /Applications "$DMG_STAGING/Applications"

# Embed the background image inside a hidden .background folder on the DMG.
# The Finder reads it from there when opening the volume.
mkdir -p "$DMG_STAGING/.background"
cp "assets/branding/dmg_background.png" "$DMG_STAGING/.background/dmg_background.png"

# Detach any stale "Install BetterCast" volumes from prior runs so the new mount and the
# AppleScript "tell disk BetterCast" are unambiguous.
echo "Detaching any stale BetterCast / Install BetterCast volumes..."
for stale in \
    "/Volumes/Install BetterCast" \
    "/Volumes/Install BetterCast 1" \
    "/Volumes/Install BetterCast 2" \
    "/Volumes/BetterCast" \
    "/Volumes/BetterCast 1" \
    "/Volumes/BetterCast 2"
do
    if [ -d "$stale" ]; then
        hdiutil detach "$stale" -force >/dev/null 2>&1 || true
    fi
done

# Build a writable DMG first so we can run AppleScript against the mounted volume,
# then convert to a compressed UDZO image once the layout is committed.
TEMP_DMG="BetterCast.tmp.dmg"
rm -f "$TEMP_DMG"
hdiutil create -volname "Install BetterCast" \
    -srcfolder "$DMG_STAGING" \
    -fs HFS+ \
    -format UDRW \
    -ov \
    "$TEMP_DMG"

# Capture the device node assigned by hdiutil so we can detach it specifically,
# regardless of how the mount-point path got disambiguated.
ATTACH_OUTPUT=$(hdiutil attach "$TEMP_DMG" -nobrowse -noautoopen -readwrite)
MOUNT_DEV=$(echo "$ATTACH_OUTPUT" | grep "Apple_HFS" | awk '{print $1}')
MOUNT_POINT=$(echo "$ATTACH_OUTPUT" | grep "Apple_HFS" | sed -E 's#^[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+##')
if [ -z "$MOUNT_POINT" ] || [ -z "$MOUNT_DEV" ]; then
    echo "Failed to mount $TEMP_DMG"
    exit 1
fi
echo "Mounted at $MOUNT_POINT (device $MOUNT_DEV)"

# Layout: 600x400 window, app on left (160,200), Applications on right (440,200), 128 px icons.
# Background is a plain cloud photo (no drawn placeholders), so the real Finder icons are
# the only icons visible.
osascript <<EOF
tell application "Finder"
    tell disk "Install BetterCast"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {400, 100, 1000, 500}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 128
        set background picture of theViewOptions to file ".background:dmg_background.png"
        set position of item "BetterCast.app" of container window to {160, 200}
        set position of item "Applications" of container window to {440, 200}
        update without registering applications
        delay 1
        close
    end tell
end tell
EOF

# Give Finder a moment to flush its writes before the unmount, otherwise the
# .DS_Store containing the layout may not be persisted.
sync
sleep 2
hdiutil detach "$MOUNT_DEV" >/dev/null 2>&1 || hdiutil detach "$MOUNT_DEV" -force >/dev/null 2>&1 || true

# Convert the writable DMG to compressed read-only UDZO (final shipping format)
rm -f "$DMG_NAME"
hdiutil convert "$TEMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_NAME"
rm -f "$TEMP_DMG"

# Clean up staging
rm -rf "$DMG_STAGING"

# Sign the DMG itself (required for Gatekeeper to accept it)
echo "Signing DMG..."
codesign --force --sign "$SIGN_IDENTITY" "$DMG_NAME"

# ============================================
# Notarize DMG (if Apple ID is set)
# ============================================
if [ -n "$APPLE_ID" ]; then
    echo "Notarizing DMG..."
    xcrun notarytool submit "$DMG_NAME" \
        --apple-id "$APPLE_ID" \
        --team-id "$TEAM_ID" \
        --password "$APP_PASSWORD" \
        --wait

    echo "Stapling notarization ticket..."
    xcrun stapler staple "$DMG_NAME"
else
    echo ""
    echo "Skipping notarization (set APPLE_ID and APP_PASSWORD to enable)"
fi

echo ""
echo "============================================"
echo "  Build Complete!"
echo "============================================"
echo "App:"
echo "  - $APP_NAME (signed: $SIGN_IDENTITY)"
echo "DMG:"
echo "  - $DMG_NAME"
echo ""
echo "Installation:"
echo "  1. Open the DMG and drag BetterCast to Applications"
echo "  2. Grant Screen Recording permission when prompted"
echo "  3. Grant Accessibility permission when prompted"
