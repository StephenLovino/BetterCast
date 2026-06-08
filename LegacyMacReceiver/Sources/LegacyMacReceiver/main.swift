import AppKit
import Combine

// AppKit lifecycle (not SwiftUI @main App, which is macOS 11+) so this runs back to 10.15.
// Receiver-only: wire the shared core and drop the renderer's NSView straight into a window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let listener = ReceiverNetworkListener()
    private let decoder = ReceiverVideoDecoder()
    private let renderer = ReceiverVideoRenderer()
    private let statusLabel = NSTextField(labelWithString: "Waiting for a Mac to connect…")
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let frame = NSRect(x: 0, y: 0, width: 1280, height: 720)
        window = NSWindow(contentRect: frame,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "BetterCast Receiver"
        window.center()

        // Container hosts the video NSView (fills) + a centered status label on top.
        let container = NSView(frame: frame)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor

        let video = renderer.view
        video.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(video)

        statusLabel.textColor = .white
        statusLabel.alignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            video.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            video.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            video.topAnchor.constraint(equalTo: container.topAnchor),
            video.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            statusLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Show the listener status while waiting, and hide the overlay once a sender connects
        // (connectedClients is populated on accept — a reliable signal, unlike videoSize).
        listener.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in self?.statusLabel.stringValue = status ?? "" }
            .store(in: &cancellables)
        listener.$connectedClients
            .receive(on: DispatchQueue.main)
            .sink { [weak self] clients in self?.statusLabel.isHidden = !clients.isEmpty }
            .store(in: &cancellables)

        listener.setup(decoder: decoder, renderer: renderer)
        listener.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
