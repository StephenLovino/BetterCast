import Foundation

/// Finds the adb binary, wherever the user got it from.
///
/// The sender only ever looked at /opt/homebrew/bin/adb, Homebrew's location on Apple
/// Silicon. With adb from Android Studio's SDK, Homebrew on an Intel Mac, MacPorts or
/// a downloaded platform-tools folder, `adb devices` worked in Terminal while the app
/// never offered USB for the plugged-in phone (#70). An app launched from Finder doesn't
/// inherit the shell's PATH, so the last resort asks a login shell where adb is.
enum ADBLocator {
    private static let lock = NSLock()
    private static var cached: String?
    /// When the last search came up empty. adb is polled every couple of seconds, and
    /// the login-shell fallback is too slow to rerun on every poll.
    private static var lastMiss: Date?

    /// The adb path, or nil if none can be found. Cached once found.
    static var path: String? {
        lock.lock(); defer { lock.unlock() }
        if let cached, FileManager.default.isExecutableFile(atPath: cached) { return cached }
        if let lastMiss, Date().timeIntervalSince(lastMiss) < 60 { return nil }
        cached = locate()
        if let cached {
            lastMiss = nil
            LogManager.shared.log("ADB: using \(cached)")
        } else {
            lastMiss = Date()
            LogManager.shared.log("ADB: adb not found in the usual places or the login shell's PATH")
        }
        return cached
    }

    private static func locate() -> String? {
        let env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        var candidates = [
            "/opt/homebrew/bin/adb",                               // Homebrew, Apple Silicon
            "/usr/local/bin/adb",                                  // Homebrew, Intel
            "\(home)/Library/Android/sdk/platform-tools/adb",      // Android Studio
            "/opt/local/bin/adb",                                  // MacPorts
            "\(home)/platform-tools/adb",                          // downloaded platform-tools
            "\(home)/Downloads/platform-tools/adb",
            "\(home)/Desktop/platform-tools/adb",
            "/Applications/platform-tools/adb",
        ]
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let sdk = env[key], !sdk.isEmpty { candidates.insert("\(sdk)/platform-tools/adb", at: 0) }
        }
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        return fromLoginShell()
    }

    /// `command -v adb` in the user's login shell, which loads their PATH from
    /// .zprofile/.zshrc the way Terminal does.
    private static func fromLoginShell() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lic", "command -v adb"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        // A broken shell profile must not hang the app.
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline { usleep(50_000) }
        if process.isRunning { process.terminate(); return nil }
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let line = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("/") && $0.hasSuffix("/adb") }
        guard let line, FileManager.default.isExecutableFile(atPath: line) else { return nil }
        return line
    }
}
