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
    /// Direct link to the .dmg asset, as opposed to `downloadURL` which is the
    /// release page. Opening a web page and leaving the user to find the file, save
    /// it and mount it is four steps to install a fix they already agreed to.
    @Published var assetURL: String?
    @Published var downloadProgress: Double = 0
    @Published var isDownloading = false
    @Published var downloadError: String?
    @Published var releaseNotes: String?
    @Published var updateAvailable = false
    @Published var checkedOnce = false
    fileprivate var progressObservation: NSKeyValueObservation?

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

            // Prefer the Mac disk image. A release also carries the Android and
            // Windows assets, so pick by extension rather than taking the first.
            let assets = json["assets"] as? [[String: Any]] ?? []
            let dmg = assets.first { ($0["name"] as? String)?.hasSuffix(".dmg") == true }
            let dmgURL = dmg?["browser_download_url"] as? String

            DispatchQueue.main.async {
                self?.latestVersion = tagName
                self?.downloadURL = htmlURL
                self?.assetURL = dmgURL
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

extension UpdateChecker {

    /// Fetch the new version and open it, so updating is one click rather than a
    /// trip to a web page.
    ///
    /// Deliberately stops at opening the mounted image rather than replacing the
    /// running app in place. Swapping a running bundle needs a helper process and a
    /// relaunch dance, and getting that subtly wrong leaves someone with no working
    /// app at all. Finder's copy is the step people already know.
    func downloadAndOpen() {
        guard !isDownloading else { return }
        guard let urlString = assetURL, let url = URL(string: urlString) else {
            // No .dmg on the release: fall back to the page rather than doing nothing.
            if let page = downloadURL, let u = URL(string: page) { NSWorkspace.shared.open(u) }
            return
        }

        isDownloading = true
        downloadProgress = 0
        downloadError = nil
        LogManager.shared.log("Update: downloading \(url.lastPathComponent)")

        let task = URLSession.shared.downloadTask(with: url) { [weak self] tmp, response, error in
            DispatchQueue.main.async { self?.isDownloading = false }

            if let error = error {
                DispatchQueue.main.async {
                    self?.downloadError = error.localizedDescription
                    LogManager.shared.log("Update: download failed — \(error.localizedDescription)")
                }
                return
            }
            guard let tmp = tmp else { return }

            // Move out of the temporary directory, which is emptied from under us,
            // and into Downloads where the file is findable if anything goes wrong.
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let dest = downloads.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.moveItem(at: tmp, to: dest)
            } catch {
                DispatchQueue.main.async {
                    self?.downloadError = error.localizedDescription
                    LogManager.shared.log("Update: could not save — \(error.localizedDescription)")
                }
                return
            }

            DispatchQueue.main.async {
                LogManager.shared.log("Update: saved to \(dest.path), opening it")
                NSWorkspace.shared.open(dest)
            }
        }

        // Progress is worth showing: the disk image is several megabytes and a button
        // that does nothing visible for ten seconds reads as broken.
        progressObservation = task.progress.observe(\.fractionCompleted) { [weak self] p, _ in
            DispatchQueue.main.async { self?.downloadProgress = p.fractionCompleted }
        }
        task.resume()
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
        Entry(version: "v21", date: "2026-09-07", highlights: [
            "Compatibility Mode no longer shows a copy of your Mac's screen instead of the extra desktop, and the pointer is visible on the receiver again",
            "Compatibility Mode is now set per device, so watching protected video on one screen no longer costs every other screen its sound",
            "Audio now says when Compatibility Mode is blocking it, instead of looking switched on and quietly sending nothing",
            "Pick the codec before you connect, not only afterwards",
            "Two receivers no longer draw on top of each other in Overview, and taps land where you touch after macOS rearranges the displays",
            "One wireless screen can no longer starve another: a device that backs off keeps its share instead of handing it to the device that never does",
            "Dim an individual receiver from its own settings, without changing your Mac's brightness",
            "An Android on the cable now appears as one device offering USB, rather than a second entry in the list",
            "Switch a connected Android between USB, ADB Wi-Fi and direct Wi-Fi, instead of only the first two",
            "The arrow in the installer window no longer disappears behind the Applications folder",
        ]),
        Entry(version: "v20", date: "2026-09-06", highlights: [
            "See your iPhone or iPad on this Mac. Plug it in, unlock it, and pick it under Receive. Nothing to install on the phone",
            "Sound from the phone plays through your Mac, and the window takes the phone's shape, including when you rotate it",
            "Update Now actually updates: it downloads the new version and opens it, instead of sending you to a web page",
            "Clicking the app icon reopens the window after you close it",
            "Streams no longer flood the network on Wi-Fi, which was causing seconds of lag on Windows receivers",
            "Quality settles at a level your network can hold instead of repeatedly overshooting and dropping back",
        ]),
        Entry(version: "v19", date: "2026-08-25", highlights: [
            "Stream to an iPhone or iPad over the cable, no network needed. Pick USB Cable on the device, and open BetterCast on it first",
            "Pull the cable mid-session and the screen carries on over Wi-Fi instead of dropping",
            "Dragging with one finger now works in touch mode, and actually drags: text selects, windows move, sliders follow",
            "Double-tap registers as a double-click, so folders open and words select",
            "Scrolling follows your Mac's Natural scrolling setting instead of always going the other way",
            "Each device keeps its place in Arrange between sessions rather than reappearing on the right",
            "A device now has to be allowed before it can use your screen",
            "Connecting no longer goes black for several seconds while the link is negotiated",
            "Apple Pencil pressure and tilt are sent to the Mac (new, and untested on hardware here)",
        ]),
        Entry(version: "v18", date: "2026-08-19", highlights: [
            "Wi-Fi streams no longer pixelate when things move — congestion now costs a moment of smoothness instead of picture corruption",
            "H.265 (HEVC) support: noticeably more detail at the same bitrate. Set it per device in the device's settings; Mac and Android receivers decode it",
            "New 5K Retina profile — use an old 5K iMac as a wireless or Thunderbolt display (the Target Display Mode revival)",
            "Multiple receivers now share bandwidth by what each actually uses, so an idle device no longer starves a busy one",
            "Android connects ~6 seconds faster (it was being dialled as an Apple device first)",
            "Per-device Smooth Motion option for burst-heavy scenes",
            "Connecting now shows progress instead of a dead button",
            "Logs gained per-second stream stats (fps, Mbps, frame age) for much easier troubleshooting",
        ]),
        Entry(version: "v17", date: "2026-08-18", highlights: [
            // Listed under v16 until now, but the v16 build never actually contained the
            // .lproj resources — they landed after that tag. This is the first release
            // that ships them, so this is where the line belongs.
            "App now follows your system language — Chinese, Japanese, Korean, German, French",
            "Much sharper picture over Wi-Fi — fixes the blur on faces and scene changes",
            "Wi-Fi streams now run at 30 FPS by default: fewer dropped frames means the detail survives (force 60 in Frame Rate if you prefer)",
            "Fixed stuttering when an iPhone and an Android stream at the same time",
            "Fixed streams that connected and then immediately dropped",
            "Android: connect to your Mac from the phone, no cable or ADB needed",
            "Android: redesigned to match the iOS app, with light mode and a trackpad cursor mode",
            "Wireless ADB is now a fallback — connecting directly is faster",
        ]),
        Entry(version: "v16", date: "2026-07-09", highlights: [
            "Retina mode fixed: displays now come up at the resolution you picked (was half-size, e.g. 1280x800)",
            "USB / Thunderbolt Cable mode now actually carries the stream to Mac receivers (was WiFi-only)",
            "Faster typing and cursor response on Android USB",
            "Frame rate is user-configurable (Auto / 30 / 60 / 120)",
        ]),
        Entry(version: "v13", date: "2026-06-05", highlights: [
            "Switch an Android device between WiFi and USB without disconnecting first",
        ]),
        Entry(version: "v12", date: "2026-06-05", highlights: [
            "Fixed a crash introduced in v11 (adaptive bitrate)",
        ]),
        Entry(version: "v11", date: "2026-06-04", highlights: [
            "Adaptive bitrate over WiFi — auto-matches quality to your network, less pixelation",
            "Smoother WiFi at 60 FPS (was 30) for fluid cursor and motion",
        ]),
        Entry(version: "v10", date: "2026-06-03", highlights: [
            "Android receiver now plays streamed audio",
            "Lower input latency when typing on an extended display",
        ]),
        Entry(version: "v9", date: "2026-06-03", highlights: [
            "Fixed Android USB (ADB) streaming — now mirrors to the device, not the Mac",
            "Lower idle CPU & battery — stopped a runaway background screen capture",
            "Smoother WiFi (TCP) streaming with near-instant recovery from pixelation",
            "Now runs on macOS 13 Ventura (previously required macOS 14)",
            "Clearer Android ADB connection errors",
        ]),
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
                        if updateChecker.isDownloading {
                            ProgressView(value: updateChecker.downloadProgress)
                                .frame(width: 90)
                            Text("\(Int(updateChecker.downloadProgress * 100))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        } else {
                            Button("Update Now") {
                                updateChecker.downloadAndOpen()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
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
