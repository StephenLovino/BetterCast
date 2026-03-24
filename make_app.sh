#!/bin/bash

# Exit on error
set -e

VERSION="v93"

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
BUILD_DIR=".build/apple/Products/Release"
SENDER_APP="BetterCastSender.app"
RECEIVER_APP="BetterCastReceiver.app"
DMG_NAME="BetterCast.dmg"
DMG_STAGING="dmg_staging"

# Clean old artifacts
rm -rf "$SENDER_APP" "$RECEIVER_APP" "$DMG_STAGING" "$DMG_NAME"

# ============================================
# Sender App
# ============================================
echo "Creating $SENDER_APP..."
mkdir -p "$SENDER_APP/Contents/MacOS"
mkdir -p "$SENDER_APP/Contents/Resources"
cp "$BUILD_DIR/BetterCastSender" "$SENDER_APP/Contents/MacOS/"
cp "BetterCastSender-Info.plist" "$SENDER_APP/Contents/Info.plist"
cp "BetterCastIcon.icns" "$SENDER_APP/Contents/Resources/AppIcon.icns"

# Code sign with entitlements
codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" --entitlements "BetterCastSender-Release.entitlements" "$SENDER_APP"

# ============================================
# Receiver App
# ============================================
echo "Creating $RECEIVER_APP..."
mkdir -p "$RECEIVER_APP/Contents/MacOS"
mkdir -p "$RECEIVER_APP/Contents/Resources"
cp "BetterCastIcon.icns" "$RECEIVER_APP/Contents/Resources/AppIcon.icns"
cp "$BUILD_DIR/BetterCastReceiver" "$RECEIVER_APP/Contents/MacOS/"

cat <<PLIST > "$RECEIVER_APP/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>BetterCastReceiver</string>
    <key>CFBundleIdentifier</key>
    <string>com.bettercast.receiver</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>BetterCastReceiver</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# Code sign receiver
codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" "$RECEIVER_APP"

# ============================================
# Create DMG
# ============================================
echo "Creating DMG..."
mkdir -p "$DMG_STAGING"
cp -R "$SENDER_APP" "$DMG_STAGING/"
cp -R "$RECEIVER_APP" "$DMG_STAGING/"

# Create a symlink to /Applications for drag-to-install
ln -s /Applications "$DMG_STAGING/Applications"

# Create DMG from staging folder
hdiutil create -volname "BetterCast" \
    -srcfolder "$DMG_STAGING" \
    -ov -format UDZO \
    "$DMG_NAME"

# Clean up staging
rm -rf "$DMG_STAGING"

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
echo "Apps:"
echo "  - $SENDER_APP (signed: $SIGN_IDENTITY)"
echo "  - $RECEIVER_APP (signed: $SIGN_IDENTITY)"
echo "DMG:"
echo "  - $DMG_NAME"
echo ""
echo "Installation:"
echo "  1. Open the DMG and drag apps to Applications"
echo "  2. Grant Screen Recording permission when prompted (Sender)"
echo "  3. Grant Accessibility permission when prompted (Sender)"
