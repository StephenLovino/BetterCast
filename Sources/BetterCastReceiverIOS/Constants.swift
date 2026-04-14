import Foundation

/// Shared constants for the BetterCast iOS receiver app.
enum BCConstants {
    /// Standard TCP port for BetterCast video/audio stream.
    static let tcpPort: UInt16 = 51820

    /// Standard UDP port for chunked frame delivery.
    static let udpPort: UInt16 = 51821

    /// Bonjour service types advertised on the local network.
    static let tcpServiceType = "_bettercast._tcp"
    static let udpServiceType = "_bettercast._udp"

    /// AAC-LC frame size in samples.
    static let aacFrameSize: UInt32 = 1024

    /// Default audio sample rate (Hz) for AAC decode.
    static let audioSampleRate: Double = 48_000

    /// Audio channel count for stereo output.
    static let audioChannels: UInt32 = 2

    /// Preferred audio IO buffer duration (seconds). Lower = lower latency.
    static let audioIOBufferDuration: TimeInterval = 0.005
}
