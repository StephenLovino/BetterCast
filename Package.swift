// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "BetterCast",
    platforms: [
        .macOS(.v14) // Target modern macOS for ScreenCaptureKit
    ],
    products: [
        .executable(name: "BetterCastSender", targets: ["BetterCastSender"]),
        .executable(name: "BetterCastReceiver", targets: ["BetterCastReceiver"]),
    ],
    targets: [
        // Static library for Objective-C VirtualDisplay code
        .target(
            name: "VirtualDisplayLib",
            path: "Sources/BetterCastSender/VirtualDisplay",
            publicHeadersPath: ".",
            cSettings: [
                .headerSearchPath(".")
            ]
        ),
        .executableTarget(
            name: "BetterCastSender",
            dependencies: ["VirtualDisplayLib"],
            exclude: ["VirtualDisplay"],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("Network"),
                .linkedFramework("CoreGraphics")
            ]
        ),
        .executableTarget(
            name: "BetterCastReceiver",
            linkerSettings: [
                .linkedFramework("CoreMedia"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("Network"),
                .linkedFramework("AVFoundation")
            ]
        ),
    ]
)
