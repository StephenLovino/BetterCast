import Foundation

/// Shared constants for the BetterCast macOS receiver app.
enum BCConstants {
    /// Standard TCP port for BetterCast video/audio stream.
    static let tcpPort: UInt16 = 51820

    /// Standard UDP port for chunked frame delivery.
    static let udpPort: UInt16 = 51821

    /// Bonjour service types advertised on the local network.
    static let tcpServiceType = "_bettercast._tcp"
    static let udpServiceType = "_bettercast._udp"

    /// Android Debug Bridge (ADB) executable path.
    static let adbPath = "/usr/local/bin/adb"

    /// Default Android screen size when device hasn't reported its dimensions yet.
    static let defaultAndroidWidth = 1080
    static let defaultAndroidHeight = 2400
}
