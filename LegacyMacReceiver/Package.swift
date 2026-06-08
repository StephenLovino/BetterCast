// swift-tools-version: 5.9
import PackageDescription

// Standalone receiver-only app for older macOS (10.15 Catalina, 11 Big Sur, 12 Monterey)
// where the main BetterCast app can't run (its UI needs macOS 13: NavigationSplitView,
// LabeledContent, .formStyle). Shares the receiver core via symlinks (no drift) and ships
// a minimal AppKit shell. Receiver-only — no ScreenCaptureKit / sender code.
let package = Package(
    name: "LegacyMacReceiver",
    platforms: [.macOS(.v10_15)],
    targets: [
        .executableTarget(name: "LegacyMacReceiver", path: "Sources/LegacyMacReceiver")
    ]
)
