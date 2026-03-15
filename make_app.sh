#!/bin/bash

# Exit on error
set -e

VERSION="v89"

echo "============================================"
echo "  Building BetterCast $VERSION (Universal Binary)"
echo "============================================"
swift build -c release --arch arm64 --arch x86_64

# Define Paths
BUILD_DIR=".build/apple/Products/Release"
SENDER_APP="BetterCastSender.app"
RECEIVER_APP="BetterCastReceiver.app"
DMG_NAME="BetterCast_${VERSION}.dmg"
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

# Ad-hoc sign with entitlements
codesign --force --deep --sign - --entitlements "BetterCastSender.entitlements" "$SENDER_APP"

# Strip quarantine attribute (prevents "damaged" error for local builds)
xattr -cr "$SENDER_APP" 2>/dev/null || true

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

# Ad-hoc sign receiver
codesign --force --deep --sign - "$RECEIVER_APP"

# Strip quarantine attribute
xattr -cr "$RECEIVER_APP" 2>/dev/null || true

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
hdiutil create -volname "BetterCast $VERSION" \
    -srcfolder "$DMG_STAGING" \
    -ov -format UDZO \
    "$DMG_NAME"

# Clean up staging
rm -rf "$DMG_STAGING"

echo ""
echo "============================================"
echo "  Build Complete!"
echo "============================================"
echo "Apps:"
echo "  - $SENDER_APP"
echo "  - $RECEIVER_APP"
echo "DMG:"
echo "  - $DMG_NAME"
echo ""
echo "Installation:"
echo "  1. Open the DMG and drag apps to Applications"
echo "  2. First launch: right-click the app > Open"
echo "     (or go to Settings > Privacy & Security > Open Anyway)"
echo "  3. Grant Screen Recording permission when prompted (Sender)"
echo "  4. Grant Accessibility permission when prompted (Sender)"
