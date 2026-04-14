#!/bin/bash

# Exit on error
set -e

VERSION="v8"

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

# Code sign with entitlements
codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" --entitlements "BetterCastSender-Release.entitlements" "$APP_NAME"

# ============================================
# Create DMG
# ============================================
echo "Creating DMG..."
mkdir -p "$DMG_STAGING"
cp -R "$APP_NAME" "$DMG_STAGING/"

# Create a symlink to /Applications for drag-to-install
ln -s /Applications "$DMG_STAGING/Applications"

# Create DMG from staging folder
hdiutil create -volname "BetterCast" \
    -srcfolder "$DMG_STAGING" \
    -ov -format UDZO \
    "$DMG_NAME"

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
