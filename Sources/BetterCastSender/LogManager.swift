import SwiftUI

class LogManager: ObservableObject {
    static let shared = LogManager()
    @Published var logs: [String] = []

    func log(_ message: String) {
        DispatchQueue.main.async {
            let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            self.logs.append("[\(timestamp)] \(message)")
            if self.logs.count > 200 {
                self.logs.removeFirst()
            }
            print(message)
        }
    }
}

// MARK: - Update Checker

class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    /// Reads version from Info.plist (CFBundleShortVersionString), prefixed with "v"
    static var currentVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        // Extract major version number to match GitHub tag format (e.g., "8.0" → "v8")
        let major = short.components(separatedBy: ".").first ?? short
        return "v\(major)"
    }

    static var displayVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(short) (\(build))"
    }

    private static let repoOwner = "StephenLovino"
    private static let repoName = "BetterCast"

    @Published var latestVersion: String?
    @Published var downloadURL: String?
    @Published var releaseNotes: String?
    @Published var updateAvailable = false
    @Published var checkedOnce = false

    /// Extracts the leading integer from a version tag like "v8", "V7", "v10.2" → 8, 7, 10
    static func versionNumber(from tag: String) -> Int {
        let digits = tag.drop(while: { !$0.isNumber })
        return Int(digits.prefix(while: { $0.isNumber })) ?? 0
    }

    func checkForUpdates() {
        let urlString = "https://api.github.com/repos/\(Self.repoOwner)/\(Self.repoName)/releases/latest"
        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let data = data, error == nil else { return }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

            let tagName = json["tag_name"] as? String ?? ""
            let htmlURL = json["html_url"] as? String ?? ""
            let body = json["body"] as? String ?? ""

            DispatchQueue.main.async {
                self?.latestVersion = tagName
                self?.downloadURL = htmlURL
                self?.releaseNotes = body

                // Numeric comparison: only show update if remote version > local version
                let remoteNum = Self.versionNumber(from: tagName)
                let localNum = Self.versionNumber(from: Self.currentVersion)
                self?.updateAvailable = remoteNum > localNum

                self?.checkedOnce = true
                if self?.updateAvailable == true {
                    LogManager.shared.log("Update: \(tagName) available (current: \(Self.currentVersion))")
                }
            }
        }.resume()
    }
}

// MARK: - Changelog

struct Changelog {
    struct Entry: Identifiable {
        let id = UUID()
        let version: String
        let date: String
        let highlights: [String]
    }

    static let entries: [Entry] = [
        Entry(version: "v8", date: "2026-03-30", highlights: [
            "Unified sender + receiver in a single app",
            "Apple Music-style sidebar with tinted selection",
            "Guided onboarding tour with spotlight highlights",
            "In-app update checker via GitHub Releases",
            "Report Issue button with auto-attached logs",
            "Display arrangement overview with live thumbnails",
            "Receiver video opens in separate window",
        ]),
        Entry(version: "v7", date: "2026-03-23", highlights: [
            "Android ADB wireless auto-reconnect",
            "Orientation fix for rotated displays",
            "Receiver UI improvements",
        ]),
        Entry(version: "v6", date: "2026-03-19", highlights: [
            "Android sender mode via MediaProjection + ADB",
            "Windows sender Phase 1",
            "DMG signing improvements",
        ]),
        Entry(version: "v5", date: "2026-03-15", highlights: [
            "TCP heartbeat + flow control fixes",
            "Audio streaming pipeline (sender AAC → receiver)",
            "Desktop receiver with Qt6 + FFmpeg",
        ]),
    ]
}

// MARK: - Log View

struct LogView: View {
    @ObservedObject var logManager = LogManager.shared
    @ObservedObject var updateChecker = UpdateChecker.shared

    private static let repoOwner = "StephenLovino"
    private static let repoName = "BetterCast"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Update banner
            if updateChecker.checkedOnce {
                if updateChecker.updateAvailable, let version = updateChecker.latestVersion {
                    HStack {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundColor(.green)
                        Text("Update available: \(version)")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Button("Download") {
                            if let urlStr = updateChecker.downloadURL, let url = URL(string: urlStr) {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.green.opacity(0.1))
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                } else {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("You're on the latest version (\(UpdateChecker.currentVersion))")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                }
            }

            // Action buttons
            HStack {
                Spacer()

                Button {
                    openReportIssue()
                } label: {
                    Label("Report Issue", systemImage: "exclamationmark.bubble")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    let text = logManager.logs.joined(separator: "\n")
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(text, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    logManager.logs.removeAll()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(logManager.logs, id: \.self) { log in
                        Text(log)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Logs")
        .onAppear {
            updateChecker.checkForUpdates()
        }
    }

    private func openReportIssue() {
        let systemInfo = [
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "BetterCast \(UpdateChecker.currentVersion)",
            "Chip: \(ProcessInfo.processInfo.processorCount) cores"
        ].joined(separator: ", ")

        let recentLogs = logManager.logs.suffix(30).joined(separator: "\n")

        let body = """
        **Describe the issue:**


        **Steps to reproduce:**
        1.

        **Expected behavior:**


        **System info:** \(systemInfo)

        <details><summary>Recent Logs</summary>

        ```
        \(recentLogs)
        ```

        </details>
        """

        let encodedTitle = "Bug: ".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let encodedBody = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "https://github.com/\(Self.repoOwner)/\(Self.repoName)/issues/new?title=\(encodedTitle)&body=\(encodedBody)"

        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}
