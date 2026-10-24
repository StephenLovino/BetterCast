import SwiftUI
import Sparkle

/// In-app updates through Sparkle.
///
/// The feed (SUFeedURL) is appcast.xml on the `mac-updates` GitHub release, and every
/// update in it is signed with the EdDSA key whose public half is SUPublicEDKey in
/// Info.plist, so a tampered feed or download is refused. Sparkle checks in the
/// background (SUScheduledCheckInterval), downloads, and offers to install and
/// relaunch. This replaces the old checker, which asked the GitHub API for whichever
/// release was marked "latest" (Windows and Android ones included), compared only the
/// major version, and left the user to drag the new app into Applications.
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    private let controller: SPUStandardUpdaterController
    @Published private(set) var canCheckForUpdates = false

    var updater: SPUUpdater { controller.updater }

    private init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil,
                                                  userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    var automaticallyChecks: Bool {
        get { updater.automaticallyChecksForUpdates }
        set {
            updater.automaticallyChecksForUpdates = newValue
            objectWillChange.send()
        }
    }

    var lastCheck: Date? { updater.lastUpdateCheckDate }
}

/// "Check for Updates..." for the app menu.
struct CheckForUpdatesCommand: View {
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        Button("Check for Updates...") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}

/// The update rows in Settings > About.
struct UpdateSettingsRows: View {
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        HStack {
            Toggle("Check for updates automatically", isOn: Binding(
                get: { updater.automaticallyChecks },
                set: { updater.automaticallyChecks = $0 }
            ))
            Spacer()
            Button("Check Now") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }
        if let last = updater.lastCheck {
            Text("Last checked \(last.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
