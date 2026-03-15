#!/bin/bash
set -e

echo "📦 BetterCast iOS IPA Packager v3"
echo "=================================="

# Paths
BINARY_PATH="/Users/stephenlovino_1/Library/Developer/Xcode/DerivedData/BetterCast-chgoikkxftogrmalkdmbbppsbxnc/Build/Products/Release-iphoneos/BetterCastReceiverIOS"
SWIFT_LIB_PATH="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-5.0/iphoneos"
ICON_PATH="AppIcon.png"
PLIST_PATH="Sources/BetterCastReceiverIOS/Info.plist"

# Check if binary exists
if [ ! -f "$BINARY_PATH" ]; then
    echo "❌ Binary not found at: $BINARY_PATH"
    echo "Please build the project first with: xcodebuild -scheme BetterCastReceiverIOS"
    exit 1
fi

# Clean and create structure
echo "🗑️  Cleaning old packaging..."
rm -rf ios_packaging BetterCastReceiverIOS_Universal_v3.ipa

echo "📁 Creating app bundle structure..."
mkdir -p ios_packaging/Payload/BetterCastReceiverIOS.app/Frameworks

# Copy binary
echo "📋 Copying binary..."
cp "$BINARY_PATH" ios_packaging/Payload/BetterCastReceiverIOS.app/

# Copy Info.plist
echo "📋 Copying Info.plist..."
cp "$PLIST_PATH" ios_packaging/Payload/BetterCastReceiverIOS.app/

# Copy icons
echo "🎨 Copying app icons..."
if [ -f "$ICON_PATH" ]; then
    cp "$ICON_PATH" ios_packaging/Payload/BetterCastReceiverIOS.app/AppIcon.png
    cp "$ICON_PATH" ios_packaging/Payload/BetterCastReceiverIOS.app/Default-568h@2x.png
else
    echo "⚠️  Warning: Icon not found, skipping..."
fi

# Copy Swift libraries (CRITICAL for iOS 12)
echo "📚 Bundling Swift libraries for iOS 12 compatibility..."
SWIFT_LIBS=(
    "libswiftCore.dylib"
    "libswiftFoundation.dylib"
    "libswiftNetwork.dylib"
    "libswiftDispatch.dylib"
    "libswiftObjectiveC.dylib"
    "libswiftDarwin.dylib"
    "libswiftCoreMedia.dylib"
    "libswiftCoreFoundation.dylib"
    "libswiftAVFoundation.dylib"
    "libswiftVideoToolbox.dylib"
    "libswiftUIKit.dylib"
    "libswiftCoreImage.dylib"
    "libswiftCoreGraphics.dylib"
    "libswiftCoreAudio.dylib"
    "libswiftMetal.dylib"
    "libswiftQuartzCore.dylib"
    "libswiftos.dylib"
    "libswiftsimd.dylib"
)

COPIED_COUNT=0
for lib in "${SWIFT_LIBS[@]}"; do
    if [ -f "$SWIFT_LIB_PATH/$lib" ]; then
        cp "$SWIFT_LIB_PATH/$lib" ios_packaging/Payload/BetterCastReceiverIOS.app/Frameworks/
        ((COPIED_COUNT++))
    else
        echo "  ⚠️  $lib not found, skipping..."
    fi
done

echo "  ✅ Copied $COPIED_COUNT Swift libraries"

# Create IPA
echo "🗜️  Creating IPA archive..."
cd ios_packaging
zip -r -q ../BetterCastReceiverIOS_Universal_v3.ipa Payload
cd ..

# Cleanup
echo "🧹 Cleaning up temporary files..."
rm -rf ios_packaging

# Show result
IPA_SIZE=$(du -h BetterCastReceiverIOS_Universal_v3.ipa | cut -f1)
echo ""
echo "✅ SUCCESS!"
echo "📦 IPA created: BetterCastReceiverIOS_Universal_v3.ipa ($IPA_SIZE)"
echo ""
echo "📱 Next steps:"
echo "   1. Open Sideloadly"
echo "   2. Drag BetterCastReceiverIOS_Universal_v3.ipa into it"
echo "   3. Enter your Apple ID"
echo "   4. Click 'Start'"
echo "   5. Trust the app in Settings > General > VPN & Device Management"
