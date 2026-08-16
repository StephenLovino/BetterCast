import Foundation

/// Returns the localized string for `key`, formatting any arguments into it.
///
/// Lookup goes through `Bundle.main`; `make_app.sh` copies
/// `localization/<lang>.lproj/Localizable.strings` into `Contents/Resources`.
/// The key is the English source string, so when no translation exists (or when
/// running a bare `swift run` binary outside the .app) the English text is shown.
///
/// SwiftUI `Text("…")`/`Button("…")`/etc. literals localize automatically via
/// `LocalizedStringKey` and do NOT need this helper — it exists for strings in
/// plain `String` contexts (status vars, enum display names, window titles).
/// Lives here (not its own file) because this file is symlinked into the
/// LegacyMacReceiver package, which compiles the shared receiver sources.
func tr(_ key: String, _ args: CVarArg...) -> String {
    let format = NSLocalizedString(key, comment: "")
    return args.isEmpty ? format : String(format: format, locale: Locale.current, arguments: args)
}

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

    /// TCP port the sender listens on for iOS-initiated "send to me" connections.
    /// Distinct from the receiver-mode listener on tcpPort so they don't collide.
    static let senderInvitePort: UInt16 = 51822
    /// Bonjour service type the sender advertises so iOS receivers can discover and dial it.
    static let senderInviteServiceType = "_bettercast-sender._tcp"

    /// Host-side (Mac) port for the ADB USB/WiFi tunnel: `adb forward tcp:<this> tcp:51820`.
    /// MUST differ from tcpPort — when BetterCast runs as both sender and receiver, the
    /// receiver listener already owns 51820, so `adb forward` can't bind it and the sender's
    /// localhost connection loops back into the Mac's own receiver instead of reaching Android.
    static let adbForwardPort: UInt16 = 51823

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
    /// Where the Support button sends people.
    ///
    /// BetterCast for Mac ships outside the App Store (Developer ID + DMG), so Apple's
    /// in-app-purchase rules do not apply and this can point anywhere. Keep it off the
    /// iOS build: App Store donation rules are a separate question and not worth
    /// entangling with a release that has only just been approved.
    static let donateURL = "https://whop.com/bettercast/bettercast-donate/"

    /// Author credit link in the settings footer.
    static let authorGitHubURL = "https://github.com/StephenLovino"

    static let defaultAndroidWidth = 1080
    static let defaultAndroidHeight = 2400
}
