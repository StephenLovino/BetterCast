#!/bin/bash

# Exit on error
set -e

echo "Building BetterCast (Universal Binary)..."
swift build -c release --arch arm64 --arch x86_64

# Define Paths
BUILD_DIR=".build/apple/Products/Release"
SENDER_APP="BetterCastSender.app"
RECEIVER_APP="BetterCastReceiver.app"

# Clean old apps
rm -rf "$SENDER_APP" "$RECEIVER_APP"

echo "Creating $SENDER_APP..."
mkdir -p "$SENDER_APP/Contents/MacOS"
mkdir -p "$SENDER_APP/Contents/Resources"
cp "$BUILD_DIR/BetterCastSender" "$SENDER_APP/Contents/MacOS/"
cp "BetterCastSender-Info.plist" "$SENDER_APP/Contents/Info.plist"

# Ad-hoc sign to clean up any attribute issues
codesign --force --deep --sign - --entitlements "BetterCastSender.entitlements" "$SENDER_APP"

echo "Creating $RECEIVER_APP..."
mkdir -p "$RECEIVER_APP/Contents/MacOS"
cp "$BUILD_DIR/BetterCastReceiver" "$RECEIVER_APP/Contents/MacOS/"
# Using same plist structure (modified ID) for receiver if needed, but receiver doesn't need TCC
cat <<EOF > "$RECEIVER_APP/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>BetterCastReceiver</string>
    <key>CFBundleIdentifier</key>
    <string>com.bettercast.receiver</string>
    <key>CFBundleName</key>
    <string>BetterCastReceiver</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF
codesign --force --deep --sign - "$RECEIVER_APP"

echo "Done! Apps created:"
echo "- $SENDER_APP"
echo "- $RECEIVER_APP"
echo ""
echo "To run and trigger permissions:"
echo "1. open $SENDER_APP"
