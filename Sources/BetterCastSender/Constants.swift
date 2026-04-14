import Foundation

/// Shared constants for the BetterCast sender app.
/// Centralizes magic numbers, ports, paths, and dimensions that were previously
/// duplicated across multiple files.
enum BCConstants {

    // MARK: - Network
    /// Standard TCP port for BetterCast video/audio stream.
    /// All BetterCast receivers listen here. Windows/Linux/Android senders
    /// rely on this being constant since they may not parse mDNS SRV records.
    static let tcpPort: UInt16 = 51820

    /// Standard UDP port for chunked frame delivery.
    static let udpPort: UInt16 = 51821

    /// Bonjour service types advertised on the local network.
    static let tcpServiceType = "_bettercast._tcp"
    static let udpServiceType = "_bettercast._udp"

    // MARK: - Audio
    /// AAC-LC frame size in samples. Required by the AAC encoder/decoder.
    static let aacFrameSize: UInt32 = 1024

    /// Default audio sample rate (Hz) for AAC encode/decode.
    static let audioSampleRate: Double = 48_000

    /// Audio channel count for stereo output.
    static let audioChannels: UInt32 = 2

    /// AAC bitrate in bits per second.
    static let aacBitrate: UInt32 = 128_000

    // MARK: - System Tools
    /// macOS TCC reset utility — used to reset Screen Recording permissions.
    static let tccutilPath = "/usr/bin/tccutil"

    /// Android Debug Bridge (ADB) executable path. Installed via Android Studio
    /// platform-tools; users without it get a friendly error.
    static let adbPath = "/usr/local/bin/adb"

    // MARK: - Display Defaults
    /// Default Android screen size when device hasn't reported its dimensions yet.
    /// Matches a typical phone resolution in landscape.
    static let defaultAndroidWidth = 1080
    static let defaultAndroidHeight = 2400
}
