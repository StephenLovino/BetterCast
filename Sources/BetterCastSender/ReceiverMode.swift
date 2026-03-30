import SwiftUI
import Network
import Combine
import AppKit

// MARK: - Receiver Video Window

/// Manages a separate NSWindow for displaying received video.
class ReceiverWindowController {
    private var window: NSWindow?
    private var lastVideoSize: CGSize = .zero

    var isOpen: Bool { window != nil }

    func open(renderer: ReceiverVideoRenderer) {
        guard window == nil else {
            window?.orderFront(nil)
            return
        }

        // Position the video window to the right of the main app window
        let mainFrame = NSApp.mainWindow?.frame
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)

        let videoWidth: CGFloat = 960
        let videoHeight: CGFloat = 540
        let videoOrigin: NSPoint
        if let mainFrame = mainFrame {
            // Place to the right of the main window, or if no room, to the left
            let rightX = mainFrame.maxX + 12
            if rightX + videoWidth <= screenFrame.maxX {
                videoOrigin = NSPoint(x: rightX, y: mainFrame.midY - videoHeight / 2)
            } else {
                let leftX = mainFrame.minX - videoWidth - 12
                videoOrigin = NSPoint(x: max(leftX, screenFrame.minX), y: mainFrame.midY - videoHeight / 2)
            }
        } else {
            videoOrigin = NSPoint(
                x: screenFrame.midX - videoWidth / 2,
                y: screenFrame.midY - videoHeight / 2
            )
        }

        let w = NSWindow(
            contentRect: NSRect(origin: videoOrigin, size: NSSize(width: videoWidth, height: videoHeight)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.title = "BetterCast — Receiving"
        w.backgroundColor = .black
        w.isReleasedWhenClosed = false
        w.contentMinSize = NSSize(width: 320, height: 180)
        w.collectionBehavior = [.fullScreenPrimary]

        // Place the renderer view as the window content
        w.contentView = renderer.view
        renderer.view.frame = w.contentView!.bounds
        renderer.view.autoresizingMask = [.width, .height]
        renderer.layout()

        // Show without stealing focus from the main window
        w.orderFront(nil)

        // Watch for window close
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: w,
            queue: .main
        ) { [weak self] _ in
            self?.window = nil
            self?.lastVideoSize = .zero
        }

        self.window = w
    }

    /// Resize window to match the video's aspect ratio, keeping the same area on screen.
    func resizeToFitVideo(_ size: CGSize) {
        guard let w = window, size.width > 0, size.height > 0 else { return }
        guard size != lastVideoSize else { return }
        lastVideoSize = size

        let screenFrame = w.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let aspect = size.width / size.height

        // Target: preserve roughly the same window area, but match aspect ratio
        let currentFrame = w.frame
        let currentArea = currentFrame.width * currentFrame.height
        // newW * newH = currentArea, newW / newH = aspect
        // newH = sqrt(currentArea / aspect), newW = aspect * newH
        var newHeight = sqrt(currentArea / aspect)
        var newWidth = aspect * newHeight

        // Clamp to screen bounds with some padding
        let maxW = screenFrame.width * 0.9
        let maxH = screenFrame.height * 0.9
        if newWidth > maxW {
            newWidth = maxW
            newHeight = newWidth / aspect
        }
        if newHeight > maxH {
            newHeight = maxH
            newWidth = newHeight * aspect
        }

        // Keep the window centered on its current center
        let centerX = currentFrame.midX
        let centerY = currentFrame.midY
        var newOriginX = centerX - newWidth / 2
        var newOriginY = centerY - newHeight / 2

        // Ensure the window stays on screen
        newOriginX = max(screenFrame.minX, min(newOriginX, screenFrame.maxX - newWidth))
        newOriginY = max(screenFrame.minY, min(newOriginY, screenFrame.maxY - newHeight))

        let newFrame = NSRect(x: newOriginX, y: newOriginY, width: newWidth, height: newHeight)
        w.setFrame(newFrame, display: true, animate: true)
    }

    func close() {
        window?.close()
        window = nil
    }

    func updateTitle(senderCount: Int) {
        guard let w = window else { return }
        if senderCount > 0 {
            w.title = "BetterCast — \(senderCount) sender\(senderCount == 1 ? "" : "s")"
        } else {
            w.title = "BetterCast — Receiving"
        }
    }
}

// MARK: - Receiver Manager

/// Singleton that owns receiver state so it survives sidebar navigation.
class ReceiverManager: ObservableObject {
    static let shared = ReceiverManager()

    let networkListener = ReceiverNetworkListener()
    let videoDecoder = ReceiverVideoDecoder()
    let videoRenderer = ReceiverVideoRenderer()
    let windowController = ReceiverWindowController()
    @Published var isRunning = false

    private var cancellables = Set<AnyCancellable>()

    private init() {
        // Forward child objectWillChange so SwiftUI redraws when nested state changes
        networkListener.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Auto-open/close window when clients connect/disconnect
        networkListener.$connectedClients
            .receive(on: DispatchQueue.main)
            .sink { [weak self] clients in
                guard let self = self else { return }
                if !clients.isEmpty {
                    self.windowController.open(renderer: self.videoRenderer)
                    self.windowController.updateTitle(senderCount: clients.count)
                } else if self.windowController.isOpen {
                    // Don't close window during ADB reconnect — it causes flicker
                    let isReconnecting = self.networkListener.isReconnecting
                    if !isReconnecting {
                        self.windowController.close()
                    }
                }
            }
            .store(in: &cancellables)

        // Auto-resize window when video dimensions change (e.g. portrait Android)
        videoRenderer.$videoSize
            .receive(on: DispatchQueue.main)
            .sink { [weak self] size in
                self?.windowController.resizeToFitVideo(size)
            }
            .store(in: &cancellables)
    }

    func start() {
        guard !isRunning else { return }
        networkListener.setup(decoder: videoDecoder, renderer: videoRenderer)
        videoRenderer.onInput = { [weak self] event in
            self?.networkListener.sendInputEvent(event)
        }
        networkListener.start()
        isRunning = true
        LogManager.shared.log("ReceiverMode: Started listening")
    }

    func stop() {
        windowController.close()
        networkListener.stop()
        videoDecoder.reset()
        videoRenderer.flush()
        isRunning = false
        LogManager.shared.log("ReceiverMode: Stopped")
    }

    func showWindow() {
        windowController.open(renderer: videoRenderer)
    }
}

// MARK: - Receiver Mode View (sidebar detail — controls only)

/// Receiver mode detail view — shows controls and status, video opens in separate window.
struct ReceiverModeView: View {
    @ObservedObject private var manager = ReceiverManager.shared
    @ObservedObject private var listener = ReceiverManager.shared.networkListener
    @State private var cachedLocalIPs: String = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Status header
                DashboardCard {
                    VStack(spacing: 12) {
                        Image(systemName: statusIcon)
                            .font(.system(size: 36))
                            .foregroundStyle(statusColor)

                        Text(statusTitle)
                            .font(.system(size: 18, weight: .semibold))

                        Text(statusSubtitle)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)

                        if manager.isRunning {
                            if let status = manager.networkListener.status {
                                Text(status)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Text(cachedLocalIPs)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .onAppear { refreshLocalIPs() }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }

                // Connected senders card
                if manager.isRunning && !manager.networkListener.connectedClients.isEmpty {
                    DashboardCard {
                        VStack(spacing: 12) {
                            HStack {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 10, height: 10)
                                Text("\(manager.networkListener.connectedClients.count) sender\(manager.networkListener.connectedClients.count == 1 ? "" : "s") connected")
                                    .font(.system(size: 14, weight: .semibold))
                                Spacer()
                            }

                            Button {
                                manager.showWindow()
                            } label: {
                                Label("Show Video Window", systemImage: "macwindow")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                        }
                    }
                }

                // Start/Stop button
                if manager.isRunning {
                    Button(role: .destructive) {
                        manager.stop()
                    } label: {
                        Label("Stop Listening", systemImage: "stop.fill")
                            .frame(maxWidth: 280)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else {
                    Button {
                        manager.start()
                    } label: {
                        Label("Start Listening", systemImage: "play.fill")
                            .frame(maxWidth: 280)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.green)
                }

                // Manual connect
                if manager.isRunning {
                    DashboardCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Manual Connect")
                                .font(.system(size: 14, weight: .semibold))

                            HStack(spacing: 8) {
                                TextField("Host", text: $listener.manualConnectHost)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 180)

                                TextField("Port", text: $listener.manualConnectPort)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 70)

                                Button("Connect") {
                                    if let port = UInt16(manager.networkListener.manualConnectPort) {
                                        manager.networkListener.connectTo(
                                            host: manager.networkListener.manualConnectHost,
                                            port: port
                                        )
                                    }
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }

                    // ADB connect
                    DashboardCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Android (ADB)")
                                .font(.system(size: 14, weight: .semibold))

                            Text("Connect to an Android device streaming via USB.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Button {
                                if let port = UInt16(manager.networkListener.manualConnectPort) {
                                    manager.networkListener.connectViaADB(port: port)
                                }
                            } label: {
                                Label("Connect via ADB", systemImage: "cable.connector")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Receive")
    }

    // MARK: - Status Helpers

    private var isConnected: Bool {
        manager.isRunning && !manager.networkListener.connectedClients.isEmpty
    }

    private var statusIcon: String {
        if isConnected { return "display.2" }
        if manager.isRunning { return "antenna.radiowaves.left.and.right" }
        return "display.and.arrow.down"
    }

    private var statusColor: Color {
        if isConnected { return .green }
        if manager.isRunning { return .orange }
        return .secondary
    }

    private var statusTitle: String {
        if isConnected { return "Receiving" }
        if manager.isRunning { return "Waiting for Connection" }
        return "Receiver Mode"
    }

    private var statusSubtitle: String {
        if isConnected { return "Video is playing in a separate window." }
        if manager.isRunning { return "Listening for incoming connections..." }
        return "Start listening to receive screen streams from other BetterCast senders."
    }

    private func refreshLocalIPs() {
        DispatchQueue.global(qos: .userInitiated).async {
            var ips: [String] = []
            for iface in Host.current().addresses {
                if iface.contains(".") && !iface.starts(with: "127.") {
                    ips.append(iface)
                }
            }
            let result = ips.isEmpty ? "No network detected" : "This device: " + ips.joined(separator: " / ") + " : 51820"
            DispatchQueue.main.async {
                cachedLocalIPs = result
            }
        }
    }
}
