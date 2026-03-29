import SwiftUI
import Network
import CoreMedia
import AppKit
import Security


@main
struct BetterCastReceiverApp: App {
    @NSApplicationDelegateAdaptor(ReceiverAppDelegate.self) var appDelegate
    
    // Dependencies
    @StateObject private var videoDecoder = VideoDecoder()
    @StateObject private var networkListener = NetworkListener()
    @StateObject private var videoRenderer = VideoRenderer()
    
    // v67: Logging
    init() {
        LogManager.shared.log("Receiver App Started - Version v80 (Full Screen Layout Fix)")
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                // Video Layer - Fills Screen completely
                VideoRendererView(renderer: videoRenderer)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea(.all) // Critical for Full Screen
                
                // UI Overlay - centered
                if networkListener.connectedClients.isEmpty {
                    VStack(spacing: 16) {
                        Text("Waiting for connection...")
                            .foregroundStyle(.orange)
                            .font(.headline)

                        // Connect to Android sender via ADB
                        VStack(spacing: 12) {
                            Button("Connect to Android (ADB)") {
                                if let port = UInt16(networkListener.manualConnectPort) {
                                    networkListener.connectViaADB(port: port)
                                }
                            }
                            .buttonStyle(.borderedProminent)

                            // Manual connect option
                            HStack(spacing: 8) {
                                TextField("Host", text: $networkListener.manualConnectHost)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 150)

                                TextField("Port", text: $networkListener.manualConnectPort)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 70)

                                Button("Connect") {
                                    if let port = UInt16(networkListener.manualConnectPort) {
                                        networkListener.connectTo(
                                            host: networkListener.manualConnectHost,
                                            port: port
                                        )
                                    }
                                }
                            }
                        }

                        if let status = networkListener.status, status.contains("Reconnecting") {
                            Text(status)
                                .foregroundStyle(.yellow)
                                .font(.caption)
                        }
                    }
                    .padding(20)
                    .background(.black.opacity(0.6))
                    .cornerRadius(12)
                }
            }
            .ignoresSafeArea(.all)
            .frame(minWidth: 640, minHeight: 200)
            .background(Color.black) // Ensure black background for letterboxing
            .onReceive(videoRenderer.$videoSize) { newSize in
                if newSize.width > 0 && newSize.height > 0 {
                    LogManager.shared.log("Receiver: videoSize changed to \(newSize.width)x\(newSize.height)")
                    // Delay slightly to ensure window is ready
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        resizeWindowToFit(videoWidth: newSize.width, videoHeight: newSize.height)
                    }
                }
            }
            .onAppear {
                networkListener.onDataReceived = { data in
                }
                
                networkListener.setup(decoder: videoDecoder, renderer: videoRenderer)
                
                videoRenderer.onInput = { event in
                    networkListener.sendInputEvent(event)
                }
                
                networkListener.start()
            }
        }
        .commands {
            CommandGroup(replacing: .saveItem) {
                Button("Restart Receiver 🔄") {
                    restartApp()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                
                Button("Save Logs...") {
                   saveLogs()
                }
                .keyboardShortcut("s", modifiers: .command)
            }
        }
    }
    
    private func restartApp() {
        let url = URL(fileURLWithPath: Bundle.main.bundlePath)
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        
        NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
            if error == nil {
                DispatchQueue.main.async {
                    NSApplication.shared.terminate(nil)
                }
            } else {
                LogManager.shared.log("Receiver: Failed to restart - \(error?.localizedDescription ?? "")")
            }
        }
    }
    
    private func resizeWindowToFit(videoWidth: CGFloat, videoHeight: CGFloat) {
        guard let window = NSApplication.shared.windows.first(where: { $0.isVisible }) ?? NSApplication.shared.windows.first else {
            LogManager.shared.log("Receiver: No window found for resize")
            return
        }
        let screen = window.screen ?? NSScreen.main!
        let screenFrame = screen.visibleFrame

        // Clear ALL constraints so the window can resize freely
        window.contentAspectRatio = NSSize(width: 0, height: 0)
        window.aspectRatio = NSSize(width: 0, height: 0)
        window.contentMinSize = NSSize(width: 200, height: 200)
        window.minSize = NSSize(width: 200, height: 200)

        let aspectRatio = videoWidth / videoHeight
        let isLandscape = videoWidth > videoHeight
        var winWidth: CGFloat
        var winHeight: CGFloat

        if isLandscape {
            // Landscape: fit to ~80% of screen width
            winWidth = min(screenFrame.width * 0.8, videoWidth)
            winHeight = winWidth / aspectRatio
            // If still too tall, constrain by height
            if winHeight > screenFrame.height * 0.85 {
                winHeight = screenFrame.height * 0.85
                winWidth = winHeight * aspectRatio
            }
        } else {
            // Portrait: fit to ~75% of screen height
            winHeight = min(screenFrame.height * 0.75, videoHeight)
            winWidth = winHeight * aspectRatio
            // If too wide, constrain by width
            if winWidth > screenFrame.width * 0.9 {
                winWidth = screenFrame.width * 0.9
                winHeight = winWidth / aspectRatio
            }
        }

        // Minimum usable size
        winWidth = max(winWidth, 320)
        winHeight = max(winHeight, 200)

        // Center on screen
        let x = screenFrame.origin.x + (screenFrame.width - winWidth) / 2
        let y = screenFrame.origin.y + (screenFrame.height - winHeight) / 2

        LogManager.shared.log("Receiver: Resizing window to \(Int(winWidth))x\(Int(winHeight)) for video \(Int(videoWidth))x\(Int(videoHeight)) [\(isLandscape ? "landscape" : "portrait")]")
        window.setFrame(NSRect(x: x, y: y, width: winWidth, height: winHeight), display: true, animate: true)
        window.aspectRatio = NSSize(width: videoWidth, height: videoHeight)
    }

    private func saveLogs() {
        let panel = NSSavePanel()
        panel.allowedFileTypes = ["txt"]
        panel.nameFieldStringValue = "BetterCast_Receiver_Logs.txt"
        
        if panel.runModal() == .OK, let url = panel.url {
            let logs = LogManager.shared.logs.joined(separator: "\n")
            try? logs.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

class ReceiverAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Default to landscape 16:9 window, centered
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard let window = NSApplication.shared.windows.first else { return }
            guard let screen = window.screen ?? NSScreen.main else { return }
            let screenFrame = screen.visibleFrame
            let winWidth = screenFrame.width * 0.7
            let winHeight = winWidth / (16.0 / 9.0)
            let x = screenFrame.origin.x + (screenFrame.width - winWidth) / 2
            let y = screenFrame.origin.y + (screenFrame.height - winHeight) / 2
            window.setFrame(NSRect(x: x, y: y, width: winWidth, height: winHeight), display: true)
        }
    }
}

/// Injects input events into Android via `adb shell input` commands.
class ADBInputInjector {
    private let adbPath: String
    private let deviceSerial: String?
    private var screenWidth: Int = 1080
    private var screenHeight: Int = 2400
    private let queue = DispatchQueue(label: "com.bettercast.adb-input", qos: .userInteractive)
    private var isMouseDown = false
    private var lastTapTime: Date = .distantPast
    private var lastScrollTime: Date = .distantPast

    init(adbPath: String, deviceSerial: String?) {
        self.adbPath = adbPath
        self.deviceSerial = deviceSerial
        fetchScreenSize()
    }

    private func fetchScreenSize() {
        queue.async { [weak self] in
            guard let self = self else { return }
            let output = self.runADB(["shell", "wm", "size"])
            // Output: "Physical size: 1080x2400"
            if let match = output.range(of: #"(\d+)x(\d+)"#, options: .regularExpression) {
                let sizeStr = String(output[match])
                let parts = sizeStr.split(separator: "x")
                if parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) {
                    self.screenWidth = w
                    self.screenHeight = h
                    LogManager.shared.log("ADB: Screen size \(w)x\(h)")
                }
            }
        }
    }

    func inject(_ event: InputEvent) {
        queue.async { [weak self] in
            self?.handleEvent(event)
        }
    }

    private func handleEvent(_ event: InputEvent) {
        let px = Int(event.x * Double(screenWidth))
        let py = Int(event.y * Double(screenHeight))

        switch event.type {
        case .leftMouseDown:
            isMouseDown = true
        case .leftMouseUp:
            if isMouseDown {
                isMouseDown = false
                // Tap
                runADB(["shell", "input", "tap", "\(px)", "\(py)"])
            }
        case .scrollWheel:
            // Throttle scroll — adb shell input swipe is slow, don't queue up dozens
            let now = Date()
            guard now.timeIntervalSince(lastScrollTime) > 0.3 else { return }
            lastScrollTime = now
            // Translate scroll to swipe
            let swipeDistance = 200
            let dy = event.deltaY > 0 ? -swipeDistance : swipeDistance
            let endY = min(max(py + dy, 0), screenHeight)
            runADB(["shell", "input", "swipe", "\(px)", "\(py)", "\(px)", "\(endY)", "100"])
        case .keyDown:
            // Map macOS keyCode to Android keyevent
            if let androidKey = macToAndroidKeyCode(event.keyCode) {
                runADB(["shell", "input", "keyevent", "\(androidKey)"])
            }
        case .rightMouseDown:
            // Back button
            runADB(["shell", "input", "keyevent", "4"])
        default:
            break
        }
    }

    @discardableResult
    private func runADB(_ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        var fullArgs: [String] = []
        if let serial = deviceSerial {
            fullArgs += ["-s", serial]
        }
        fullArgs += args
        process.arguments = fullArgs
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    private func macToAndroidKeyCode(_ macKey: UInt16) -> Int? {
        // Common macOS virtual key codes → Android KEYCODE
        switch macKey {
        case 36: return 66   // Return → KEYCODE_ENTER
        case 51: return 67   // Delete → KEYCODE_DEL
        case 53: return 4    // Escape → KEYCODE_BACK
        case 48: return 61   // Tab → KEYCODE_TAB
        case 49: return 62   // Space → KEYCODE_SPACE
        case 123: return 21  // Left arrow → KEYCODE_DPAD_LEFT
        case 124: return 22  // Right arrow → KEYCODE_DPAD_RIGHT
        case 125: return 20  // Down arrow → KEYCODE_DPAD_DOWN
        case 126: return 19  // Up arrow → KEYCODE_DPAD_UP
        case 115: return 122 // Home → KEYCODE_MOVE_HOME
        case 119: return 123 // End → KEYCODE_MOVE_END
        case 116: return 92  // Page Up → KEYCODE_PAGE_UP
        case 121: return 93  // Page Down → KEYCODE_PAGE_DOWN
        // Volume
        case 72: return 24   // Volume Up
        case 73: return 25   // Volume Down
        default: return nil
        }
    }
}

class NetworkListener: ObservableObject, VideoDecoderDelegate {
    private var tcpListener: NWListener?
    private var udpListener: NWListener?
    private var quicListener: NWListener?

    @Published var status: String? = "Initializing..."
    @Published var connectedClients: [NWConnection] = []
    @Published var manualConnectHost: String = "localhost"
    @Published var manualConnectPort: String = "51820"

    enum ConnectionType {
        case tcp
        case udp
        case quic
    }

    private let networkQueue = DispatchQueue(label: "com.bettercast.network", qos: .userInteractive)

    // Dependencies
    var videoRenderer: VideoRenderer?
    var onDataReceived: ((Data) -> Void)?
    var videoDecoder: VideoDecoder?
    var adbInputInjector: ADBInputInjector?

    // Auto-reconnect state
    private var lastADBPort: UInt16?
    private var lastADBPath: String?
    private var lastADBSerial: String?
    private var reconnectTimer: Timer?
    private var isReconnecting = false

    init() {}
    
    func setup(decoder: VideoDecoder, renderer: VideoRenderer) {
        self.videoDecoder = decoder
        self.videoRenderer = renderer
        decoder.delegate = self
    }

    func start() {
        startTCP()
        startUDP()
        startHeartbeat()
    }

    /// Connect to Android sender via ADB tunnel.
    /// Runs `adb forward` automatically, then connects to localhost.
    func connectViaADB(port: UInt16) {
        DispatchQueue.main.async {
            self.status = "Setting up ADB tunnel..."
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Find adb binary
            let adbPaths = [
                "/usr/local/bin/adb",
                "/opt/homebrew/bin/adb",
                "\(NSHomeDirectory())/Library/Android/sdk/platform-tools/adb",
                "/Users/\(NSUserName())/Library/Android/sdk/platform-tools/adb"
            ]
            let adbPath = adbPaths.first { FileManager.default.fileExists(atPath: $0) }

            guard let adb = adbPath else {
                DispatchQueue.main.async {
                    self?.status = "ADB not found. Install Android SDK or add adb to PATH."
                    LogManager.shared.log("Receiver: ADB binary not found at any known path")
                }
                return
            }

            // First, find a connected device (needed when multiple devices are attached)
            let deviceSerial = self?.findADBDevice(adb: adb)

            // Run: adb [-s device] forward tcp:<port> tcp:<port>
            let process = Process()
            process.executableURL = URL(fileURLWithPath: adb)
            var args: [String] = []
            if let serial = deviceSerial {
                args += ["-s", serial]
            }
            args += ["forward", "tcp:\(port)", "tcp:\(port)"]
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                process.waitUntilExit()

                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

                if process.terminationStatus == 0 {
                    let deviceInfo = deviceSerial ?? "default"
                    LogManager.shared.log("Receiver: ADB forward established on port \(port) (device: \(deviceInfo))")
                    // Save for auto-reconnect
                    self?.lastADBPort = port
                    self?.lastADBPath = adb
                    self?.lastADBSerial = deviceSerial
                    // Set up ADB input injection
                    let injector = ADBInputInjector(adbPath: adb, deviceSerial: deviceSerial)
                    DispatchQueue.main.async {
                        self?.adbInputInjector = injector
                        self?.isReconnecting = false
                        self?.stopReconnectTimer()
                    }
                    // Enable wireless ADB so connection survives USB disconnect
                    self?.enableWirelessADB(adb: adb, serial: deviceSerial)
                    // Now connect via TCP to the forwarded port
                    self?.connectTo(host: "localhost", port: port)
                } else {
                    DispatchQueue.main.async {
                        self?.status = "ADB forward failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
                        LogManager.shared.log("Receiver: ADB forward failed (\(process.terminationStatus)): \(output)")
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self?.status = "Failed to run ADB: \(error.localizedDescription)"
                    LogManager.shared.log("Receiver: Failed to run ADB: \(error)")
                }
            }
        }
    }

    /// Find a connected ADB device. Prefers USB devices over WiFi.
    private func findADBDevice(adb: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adb)
        process.arguments = ["devices"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()

            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let lines = output.components(separatedBy: "\n")
                .filter { $0.contains("\tdevice") }
                .map { $0.components(separatedBy: "\t").first ?? "" }
                .filter { !$0.isEmpty }

            if lines.count <= 1 {
                // 0 or 1 device — adb will pick it automatically
                return nil
            }

            // Multiple devices: prefer USB (no colon in serial) over WiFi (ip:port)
            let usbDevices = lines.filter { !$0.contains(":") }
            let wifiDevices = lines.filter { $0.contains(":") }

            // Prefer USB, fall back to WiFi
            return usbDevices.first ?? wifiDevices.first
        } catch {
            return nil
        }
    }

    /// Enable wireless ADB so the connection survives USB disconnect.
    private func enableWirelessADB(adb: String, serial: String?) {
        // Get device IP via adb shell
        let ipProcess = Process()
        ipProcess.executableURL = URL(fileURLWithPath: adb)
        var ipArgs: [String] = []
        if let s = serial { ipArgs += ["-s", s] }
        ipArgs += ["shell", "ip", "route", "show", "dev", "wlan0"]
        ipProcess.arguments = ipArgs
        let ipPipe = Pipe()
        ipProcess.standardOutput = ipPipe
        ipProcess.standardError = ipPipe

        do {
            try ipProcess.run()
            ipProcess.waitUntilExit()
            let ipOutput = String(data: ipPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

            // Parse "... src 192.168.x.x ..."
            guard let range = ipOutput.range(of: #"src\s+(\d+\.\d+\.\d+\.\d+)"#, options: .regularExpression),
                  let ipRange = ipOutput[range].range(of: #"\d+\.\d+\.\d+\.\d+"#, options: .regularExpression) else {
                LogManager.shared.log("Receiver: Cannot determine device WiFi IP — wireless ADB skipped")
                return
            }
            let deviceIp = String(ipOutput[ipRange])

            // Enable tcpip mode
            let tcpipProcess = Process()
            tcpipProcess.executableURL = URL(fileURLWithPath: adb)
            var tcpipArgs: [String] = []
            if let s = serial { tcpipArgs += ["-s", s] }
            tcpipArgs += ["tcpip", "5555"]
            tcpipProcess.arguments = tcpipArgs
            let tcpipPipe = Pipe()
            tcpipProcess.standardOutput = tcpipPipe
            tcpipProcess.standardError = tcpipPipe

            try tcpipProcess.run()
            tcpipProcess.waitUntilExit()

            // Wait for device to switch to TCP mode
            Thread.sleep(forTimeInterval: 1.5)

            // Connect wirelessly
            let connectProcess = Process()
            connectProcess.executableURL = URL(fileURLWithPath: adb)
            connectProcess.arguments = ["connect", "\(deviceIp):5555"]
            let connectPipe = Pipe()
            connectProcess.standardOutput = connectPipe
            connectProcess.standardError = connectPipe

            try connectProcess.run()
            connectProcess.waitUntilExit()
            let connectOutput = String(data: connectPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

            if connectOutput.contains("connected") || connectOutput.contains("already") {
                LogManager.shared.log("Receiver: Wireless ADB enabled (\(deviceIp):5555) — USB can be disconnected")
                DispatchQueue.main.async {
                    self.status = "ADB connected (wireless enabled)"
                }
            } else {
                LogManager.shared.log("Receiver: Wireless ADB connect failed: \(connectOutput.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        } catch {
            LogManager.shared.log("Receiver: Wireless ADB setup error: \(error)")
        }
    }

    /// Connect outbound to a remote sender via TCP.
    func connectTo(host: String, port: UInt16) {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.serviceClass = .interactiveVideo

        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        let connection = NWConnection(to: endpoint, using: parameters)

        LogManager.shared.log("Receiver: Connecting to \(host):\(port)...")
        DispatchQueue.main.async {
            self.status = "Connecting to \(host):\(port)..."
        }

        handleNewConnection(connection, type: .tcp)
    }
    
    private func startHeartbeat() {
        // v69 Heartbeat - send as length-prefixed JSON to match TCP framing protocol
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let heartbeatEvent = InputEvent(type: .command, keyCode: 888)
            guard let data = try? JSONEncoder().encode(heartbeatEvent) else { return }
            var packet = Data()
            var length32 = UInt32(data.count).bigEndian
            packet.append(Data(bytes: &length32, count: 4))
            packet.append(data)

            self.networkQueue.async {
                for connection in self.connectedClients {
                    connection.send(content: packet, completion: .contentProcessed({ _ in }))
                }
            }
        }
    }
    
    private func startTCP() {
        do {
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.enableKeepalive = true
            tcpOptions.noDelay = true
            let parameters = NWParameters(tls: nil, tcp: tcpOptions)
            parameters.includePeerToPeer = true
            parameters.allowLocalEndpointReuse = true
            // parameters.requiredInterfaceType = .wifi <--- REMOVED: Allow AWDL!
            parameters.serviceClass = .interactiveVideo
            
            let listener = try NWListener(using: parameters)
            listener.service = NWListener.Service(name: "BetterCast Receiver", type: "_bettercast._tcp")
            
            listener.stateUpdateHandler = { [weak self] state in
                self?.handleListenerState(state, type: "TCP")
            }
            
            listener.newConnectionHandler = { [weak self] connection in
                LogManager.shared.log("Receiver (TCP): New connection from \(connection.endpoint)")
                self?.handleNewConnection(connection, type: .tcp)
            }
            
            listener.start(queue: networkQueue)
            self.tcpListener = listener
        } catch {
            LogManager.shared.log("Receiver (TCP): Error \(error)")
        }
    }
    
    private func startUDP() {
        do {
            let parameters = NWParameters.udp
            parameters.includePeerToPeer = true
            parameters.allowLocalEndpointReuse = true
            // parameters.requiredInterfaceType = .wifi <--- REMOVED
            parameters.serviceClass = .responsiveData // Reverted to generic for compatibility with older Macs
            parameters.preferNoProxies = true
            
            let listener = try NWListener(using: parameters)
            listener.service = NWListener.Service(name: "BetterCast Receiver UDP", type: "_bettercast._udp")
            
            listener.stateUpdateHandler = { [weak self] state in
                self?.handleListenerState(state, type: "UDP")
            }
            
            listener.newConnectionHandler = { [weak self] connection in
                LogManager.shared.log("Receiver (UDP): New connection from \(connection.endpoint)")
                self?.handleNewConnection(connection, type: .udp)
            }
            
            listener.start(queue: networkQueue)
            self.udpListener = listener
        } catch {
            LogManager.shared.log("Receiver (UDP): Error \(error)")
        }
    }
    
    private func handleListenerState(_ state: NWListener.State, type: String) {
        DispatchQueue.main.async {
            switch state {
            case .ready:
                if type == "TCP" { // Only update UI status for primary TCP
                   self.status = "Ready. Advertising as _bettercast. \(type)"
                }
                LogManager.shared.log("Receiver (\(type)): Ready")
            case .failed(let error):
                if type == "TCP" { self.status = "Failed: \(error.localizedDescription)" }
                LogManager.shared.log("Receiver (\(type)): Failed \(error)")
            default:
                break
            }
        }
    }
    
    private func handleNewConnection(_ connection: NWConnection, type: ConnectionType) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                LogManager.shared.log("Receiver: \(type) Connection ready")
                DispatchQueue.main.async {
                    if let self = self {
                        if !self.connectedClients.contains(where: { $0 === connection }) {
                            self.connectedClients.append(connection)
                        }
                    }
                }
                if type == .udp {
                    self?.receiveUDP(on: connection)
                } else {
                    // TCP
                    self?.receiveTCP(on: connection)
                }
            case .failed(let error):
                LogManager.shared.log("Receiver: Connection failed \(error)")
                self?.removeConnection(connection)
            case .cancelled:
                self?.removeConnection(connection)
            default:
                break
            }
        }
        connection.start(queue: networkQueue)
    }
    
    private func receiveTCP(on connection: NWConnection) {
        // TCP is reliable, no changes needed other than queue
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] content, contentContext, isComplete, error in
            if let error = error {
                LogManager.shared.log("Receiver (TCP): Error \(error)")
                return
            }
            
            if let content = content, content.count == 4 {
                let length = content.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
                let bodyLength = Int(length)
                
                connection.receive(minimumIncompleteLength: bodyLength, maximumLength: bodyLength) { body, bodyContext, isComplete, error in
                    if let body = body {
                         self?.videoDecoder?.decode(data: body)
                    }
                    self?.receiveTCP(on: connection)
                }
            } else {
                 self?.receiveTCP(on: connection)
            }
        }
    }
    
    // UDP Reassembly Buffer
    private var udpBuffer: [UInt32: (total: Int, chunks: [UInt16: Data], time: Date)] = [:]
    private let udpLock = NSLock()
    
    // Stats
    private var udpPacketsReceived = 0
    private var udpFramesReassembled = 0
    private var udpFramesIncomplete = 0
    private var lastStatsTime = Date()
    
    private func receiveUDP(on connection: NWConnection) {
        // UDP: Message based. Receive entire datagram.
        connection.receiveMessage { [weak self] content, contentContext, isComplete, error in
            if let error = error {
                LogManager.shared.log("Receiver (UDP): Error \(error)")
                return
            }
            
            if let content = content, !content.isEmpty {
                 self?.handleUDPPacket(content)
            }
            self?.receiveUDP(on: connection) // Loop
        }
    }
    
    private var lastDecodedFrameId: UInt32 = 0
    private var lastKeyframeRequest = Date.distantPast
    
    private func handleUDPPacket(_ data: Data) {
        guard data.count > 8 else { return } // Min header size
        
        let header = data.prefix(8)
        let payload = data.dropFirst(8)
        
        let frameID = header.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self).bigEndian }
        let chunkID = header.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt16.self).bigEndian }
        let totalChunks = header.withUnsafeBytes { $0.load(fromByteOffset: 6, as: UInt16.self).bigEndian }
        
        // Lock not strictly needed if we are on serial queue, but good for safety
        udpLock.lock()
        defer { udpLock.unlock() }
        
        // Init state on first frame
        if lastDecodedFrameId == 0 { lastDecodedFrameId = frameID &- 1 }
        
        udpPacketsReceived += 1
        
        // Stats logging every 3 seconds
        if Date().timeIntervalSince(lastStatsTime) > 3.0 {
            LogManager.shared.log("Stats (3s): UDP Pkts: \(udpPacketsReceived), Frames Built: \(udpFramesReassembled), Drops/Pending: \(udpFramesIncomplete)")
            udpPacketsReceived = 0
            udpFramesReassembled = 0
            udpFramesIncomplete = 0
            lastStatsTime = Date()
        }
        
        if udpBuffer[frameID] == nil {
            udpBuffer[frameID] = (total: Int(totalChunks), chunks: [:], time: Date())
        }
        
        udpBuffer[frameID]?.chunks[chunkID] = payload
        
        if let entry = udpBuffer[frameID], entry.chunks.count == entry.total {
            udpFramesReassembled += 1
            
            // Gap Detection
            let diff = Int(frameID) - Int(lastDecodedFrameId)
            if diff > 1 && diff < 1000 { 
                 // v62: Relaxed throttle to 2.0s to match Sender's limit
                 if Date().timeIntervalSince(lastKeyframeRequest) > 2.0 {
                     LogManager.shared.log("Receiver: Frame Gap Detected (\(lastDecodedFrameId) -> \(frameID)). Requesting IDR.")
                     sendInputEvent(InputEvent(type: .command, keyCode: 999))
                     lastKeyframeRequest = Date()
                 }
            }
            lastDecodedFrameId = frameID
            
            // Reassembly complete
            let sortedChunks = entry.chunks.sorted { $0.key < $1.key }
            var fullData = Data()
            for (_, chunkData) in sortedChunks {
                fullData.append(chunkData)
            }
            
            // Decode on this serial queue (VideoDecoder uses Async Decompression, so it won't block long)
            self.videoDecoder?.decode(data: fullData)
            udpBuffer.removeValue(forKey: frameID)
            
        } else {
             // Incomplete
             udpFramesIncomplete = udpBuffer.count 
        }
        
        // Periodic Cleanup
        if udpPacketsReceived % 100 == 0 {
             for (key, val) in udpBuffer {
                if val.time.timeIntervalSinceNow < -1.0 { 
                    udpBuffer.removeValue(forKey: key)
                }
            }
        }
    }
    
    private func removeConnection(_ connection: NWConnection) {
        DispatchQueue.main.async {
            self.connectedClients.removeAll(where: { $0 === connection })
            // Auto-reconnect if this was an ADB connection and no clients remain
            if self.connectedClients.isEmpty && self.lastADBPort != nil {
                self.startReconnectTimer()
            }
        }
    }

    private func startReconnectTimer() {
        guard !isReconnecting else { return }
        isReconnecting = true
        stopReconnectTimer()
        LogManager.shared.log("Receiver: Connection lost. Will auto-reconnect via ADB...")
        DispatchQueue.main.async {
            self.status = "Reconnecting via ADB..."
        }

        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.attemptADBReconnect()
        }
        // Also try immediately
        attemptADBReconnect()
    }

    private func stopReconnectTimer() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
    }

    private func attemptADBReconnect() {
        guard let port = lastADBPort else { return }

        DispatchQueue.main.async {
            self.status = "Reconnecting via ADB..."
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // Find adb — use saved path or re-discover
            let adb: String
            if let saved = self.lastADBPath, FileManager.default.fileExists(atPath: saved) {
                adb = saved
            } else {
                let adbPaths = [
                    "/usr/local/bin/adb",
                    "/opt/homebrew/bin/adb",
                    "\(NSHomeDirectory())/Library/Android/sdk/platform-tools/adb",
                    "/Users/\(NSUserName())/Library/Android/sdk/platform-tools/adb"
                ]
                guard let found = adbPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
                    LogManager.shared.log("Receiver: ADB not found during reconnect")
                    return
                }
                adb = found
            }

            // Check if a device is connected
            let deviceSerial = self.findADBDevice(adb: adb)

            // Re-establish adb forward
            let process = Process()
            process.executableURL = URL(fileURLWithPath: adb)
            var args: [String] = []
            if let serial = deviceSerial {
                args += ["-s", serial]
            }
            args += ["forward", "tcp:\(port)", "tcp:\(port)"]
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                process.waitUntilExit()

                if process.terminationStatus == 0 {
                    LogManager.shared.log("Receiver: ADB forward re-established on port \(port)")
                    self.lastADBPath = adb
                    self.lastADBSerial = deviceSerial

                    let injector = ADBInputInjector(adbPath: adb, deviceSerial: deviceSerial)
                    DispatchQueue.main.async {
                        self.adbInputInjector = injector
                        self.isReconnecting = false
                        self.stopReconnectTimer()
                    }
                    self.connectTo(host: "localhost", port: port)
                } else {
                    LogManager.shared.log("Receiver: ADB reconnect attempt failed (no device?)")
                }
            } catch {
                LogManager.shared.log("Receiver: ADB reconnect error: \(error)")
            }
        }
    }
    
    // VideoDecoder Delegate (Called by VT callback usually, or our decode call)
    func didDecode(sampleBuffer: CMSampleBuffer) {
        // VideoRenderer MUST be updated on Main Thread
        DispatchQueue.main.async {
            self.videoRenderer?.enqueue(sampleBuffer)
        }
    }
    
    func sendInputEvent(_ event: InputEvent) {
        // ADB input injection (for Android sender control)
        if event.type != .command {
            adbInputInjector?.inject(event)
        }

        // Also send over TCP/UDP (for Mac sender control + heartbeats)
        let isCritical = (event.type == .leftMouseDown || event.type == .leftMouseUp || event.type == .rightMouseDown || event.type == .rightMouseUp || event.type == .keyDown || event.type == .keyUp || event.type == .command)

        let repeatCount = isCritical ? 3 : 1

        guard let data = try? JSONEncoder().encode(event) else { return }

        var packet = Data()
        var length32 = UInt32(data.count).bigEndian
        packet.append(Data(bytes: &length32, count: 4))
        packet.append(data)

        networkQueue.async { [weak self] in
            guard let self = self else { return }
            for connection in self.connectedClients {
                for _ in 0..<repeatCount {
                    connection.send(content: packet, completion: .contentProcessed { error in
                        if let error = error {
                            LogManager.shared.log("Receiver: Send Input Error \(error)")
                        }
                    })
                }
            }
        }
    }
}
