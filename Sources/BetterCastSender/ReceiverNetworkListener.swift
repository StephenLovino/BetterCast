import Foundation
import Network
import CoreMedia

/// Network listener for receiver mode — accepts incoming TCP/UDP connections from senders.
class ReceiverNetworkListener: ObservableObject, ReceiverVideoDecoderDelegate {
    private var tcpListener: NWListener?
    private var udpListener: NWListener?

    @Published var status: String? = "Initializing..."
    @Published var connectedClients: [NWConnection] = []
    @Published var manualConnectHost: String = "localhost"
    @Published var manualConnectPort: String = "51820"

    private let networkQueue = DispatchQueue(label: "com.bettercast.receiver-network", qos: .userInteractive)

    var videoRenderer: ReceiverVideoRenderer?
    var videoDecoder: ReceiverVideoDecoder?
    var adbInputInjector: ADBInputInjector?

    // Per-connection format detection: true = has type byte, false = legacy, nil = unknown
    private var connectionFormat: [ObjectIdentifier: Bool] = [:]

    // Auto-reconnect state
    private var lastADBPort: UInt16?       // remote port on Android
    private var lastADBLocalPort: UInt16?  // local port for ADB tunnel
    private var lastADBPath: String?
    private var lastADBSerial: String?
    private var reconnectTimer: Timer?
    private var heartbeatTimer: Timer?
    private(set) var isReconnecting = false
    private var isConnectingADB = false
    private var wirelessADBEnabled = false
    private var isStopped = false
    private var reconnectAttempts = 0
    private static let maxReconnectAttempts = 15

    init() {}

    func setup(decoder: ReceiverVideoDecoder, renderer: ReceiverVideoRenderer) {
        self.videoDecoder = decoder
        self.videoRenderer = renderer
        decoder.delegate = self
    }

    func start() {
        isStopped = false
        reconnectAttempts = 0
        // Start listeners on background queue to avoid blocking UI
        networkQueue.async { [weak self] in
            self?.startTCP()
            self?.startUDP()
        }
        // Heartbeat timer must be on main thread (needs a run loop)
        DispatchQueue.main.async { [weak self] in
            self?.startHeartbeat()
        }
    }

    func stop() {
        isStopped = true
        isReconnecting = false
        reconnectAttempts = 0
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        tcpListener?.cancel()
        tcpListener = nil
        udpListener?.cancel()
        udpListener = nil
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        lastADBPort = nil
        lastADBLocalPort = nil
        wirelessADBEnabled = false
        for connection in connectedClients {
            connection.cancel()
        }
        connectedClients.removeAll()
    }

    // MARK: - ADB

    func connectViaADB(port: UInt16) {
        guard !isConnectingADB else {
            LogManager.shared.log("Receiver: ADB connect already in progress, skipping")
            return
        }
        isConnectingADB = true

        DispatchQueue.main.async {
            self.status = "Setting up ADB tunnel..."
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
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
                }
                self?.isConnectingADB = false
                return
            }

            let deviceSerial = self?.findADBDevice(adb: adb)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: adb)
            var args: [String] = []
            if let serial = deviceSerial {
                args += ["-s", serial]
            }
            // Use a different local port to avoid conflict with our own receiver on 51820
            let localPort = port + 1  // e.g., 51821 → android:51820
            args += ["forward", "tcp:\(localPort)", "tcp:\(port)"]
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                process.waitUntilExit()

                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

                if process.terminationStatus == 0 {
                    LogManager.shared.log("Receiver: ADB forward localhost:\(localPort) → android:\(port)")
                    self?.lastADBPort = port
                    self?.lastADBLocalPort = localPort
                    self?.lastADBPath = adb
                    self?.lastADBSerial = deviceSerial
                    let injector = ADBInputInjector(adbPath: adb, deviceSerial: deviceSerial)
                    DispatchQueue.main.async {
                        self?.adbInputInjector = injector
                        self?.isReconnecting = false
                        self?.stopReconnectTimer()
                    }
                    self?.connectTo(host: "localhost", port: localPort)
                    self?.isConnectingADB = false
                } else {
                    self?.isConnectingADB = false
                    DispatchQueue.main.async {
                        self?.status = "ADB forward failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
                    }
                }
            } catch {
                self?.isConnectingADB = false
                DispatchQueue.main.async {
                    self?.status = "Failed to run ADB: \(error.localizedDescription)"
                }
            }
        }
    }

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

            if lines.count <= 1 { return nil }

            let usbDevices = lines.filter { !$0.contains(":") }
            return usbDevices.first ?? lines.first
        } catch {
            return nil
        }
    }

    private func enableWirelessADB(adb: String, serial: String?) {
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

            guard let range = ipOutput.range(of: #"src\s+(\d+\.\d+\.\d+\.\d+)"#, options: .regularExpression),
                  let ipRange = ipOutput[range].range(of: #"\d+\.\d+\.\d+\.\d+"#, options: .regularExpression) else {
                LogManager.shared.log("Receiver: Cannot determine device WiFi IP — wireless ADB skipped")
                return
            }
            let deviceIp = String(ipOutput[ipRange])

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

            Thread.sleep(forTimeInterval: 1.5)

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
                LogManager.shared.log("Receiver: Wireless ADB enabled (\(deviceIp):5555)")
                DispatchQueue.main.async {
                    self.status = "ADB connected (wireless enabled)"
                }
            }
        } catch {
            LogManager.shared.log("Receiver: Wireless ADB setup error: \(error)")
        }
    }

    // MARK: - TCP/UDP

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
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
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

    enum ConnectionType {
        case tcp
        case udp
    }

    private func startTCP() {
        do {
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.enableKeepalive = true
            tcpOptions.noDelay = true
            let parameters = NWParameters(tls: nil, tcp: tcpOptions)
            parameters.includePeerToPeer = true
            parameters.allowLocalEndpointReuse = true
            parameters.serviceClass = .interactiveVideo

            let listener = try NWListener(using: parameters, on: 51820)
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
            parameters.serviceClass = .responsiveData
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
                if type == "TCP" {
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
                        if self.lastADBPort != nil && !self.wirelessADBEnabled,
                           let adb = self.lastADBPath {
                            self.wirelessADBEnabled = true
                            // Delay 5s — adb tcpip 5555 kills USB tunnel momentarily
                            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5.0) {
                                self.enableWirelessADB(adb: adb, serial: self.lastADBSerial)
                            }
                        }
                    }
                }
                if type == .udp {
                    self?.receiveUDP(on: connection)
                } else {
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
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] content, contentContext, isComplete, error in
            if let error = error {
                LogManager.shared.log("Receiver (TCP): Error \(error)")
                return
            }

            if let content = content, content.count == 4 {
                let length = content.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
                let bodyLength = Int(length)

                connection.receive(minimumIncompleteLength: bodyLength, maximumLength: bodyLength) { body, bodyContext, isComplete, error in
                    if let body = body, !body.isEmpty {
                        self?.handleReceivedBody(body, connection: connection)
                    }
                    self?.receiveTCP(on: connection)
                }
            } else {
                self?.receiveTCP(on: connection)
            }
        }
    }

    private func handleReceivedBody(_ body: Data, connection: NWConnection) {
        let connId = ObjectIdentifier(connection)
        let hasTypeByte: Bool

        if let known = connectionFormat[connId] {
            hasTypeByte = known
        } else {
            // Auto-detect on first frame: type-byte format starts with 0x01 (video)
            // or 0x02 (audio). Legacy format starts with 8-byte PTS (little-endian),
            // where the first frame always has PTS=0 so byte[0]=0x00.
            let firstByte = body[body.startIndex]
            if firstByte == 0x01 || firstByte == 0x02 {
                hasTypeByte = true
                LogManager.shared.log("Receiver: Detected type-byte framing (desktop sender)")
            } else {
                hasTypeByte = false
                LogManager.shared.log("Receiver: Detected legacy framing (Swift sender)")
            }
            connectionFormat[connId] = hasTypeByte
        }

        if hasTypeByte {
            let typeByte = body[body.startIndex]
            let payload = Data(body.dropFirst(1))
            if typeByte == 0x01 && !payload.isEmpty {
                videoDecoder?.decode(data: payload)
            } else if typeByte == 0x02 {
                // TODO: route to audio decoder
            }
        } else {
            videoDecoder?.decode(data: body)
        }
    }

    // UDP Reassembly
    private var udpBuffer: [UInt32: (total: Int, chunks: [UInt16: Data], time: Date)] = [:]
    private let udpLock = NSLock()
    private var udpPacketsReceived = 0
    private var udpFramesReassembled = 0
    private var udpFramesIncomplete = 0
    private var lastStatsTime = Date()

    private func receiveUDP(on connection: NWConnection) {
        connection.receiveMessage { [weak self] content, contentContext, isComplete, error in
            if let error = error {
                LogManager.shared.log("Receiver (UDP): Error \(error)")
                return
            }

            if let content = content, !content.isEmpty {
                self?.handleUDPPacket(content)
            }
            self?.receiveUDP(on: connection)
        }
    }

    private var lastDecodedFrameId: UInt32 = 0
    private var lastKeyframeRequest = Date.distantPast

    private func handleUDPPacket(_ data: Data) {
        guard data.count > 8 else { return }

        let header = data.prefix(8)
        let payload = data.dropFirst(8)

        let frameID = header.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self).bigEndian }
        let chunkID = header.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt16.self).bigEndian }
        let totalChunks = header.withUnsafeBytes { $0.load(fromByteOffset: 6, as: UInt16.self).bigEndian }

        udpLock.lock()
        defer { udpLock.unlock() }

        if lastDecodedFrameId == 0 { lastDecodedFrameId = frameID &- 1 }

        udpPacketsReceived += 1

        if udpBuffer[frameID] == nil {
            udpBuffer[frameID] = (total: Int(totalChunks), chunks: [:], time: Date())
        }

        udpBuffer[frameID]?.chunks[chunkID] = payload

        if let entry = udpBuffer[frameID], entry.chunks.count == entry.total {
            udpFramesReassembled += 1

            let diff = Int(frameID) - Int(lastDecodedFrameId)
            if diff > 1 && diff < 1000 {
                if Date().timeIntervalSince(lastKeyframeRequest) > 2.0 {
                    sendInputEvent(InputEvent(type: .command, keyCode: 999))
                    lastKeyframeRequest = Date()
                }
            }
            lastDecodedFrameId = frameID

            let sortedChunks = entry.chunks.sorted { $0.key < $1.key }
            var fullData = Data()
            for (_, chunkData) in sortedChunks {
                fullData.append(chunkData)
            }

            self.videoDecoder?.decode(data: fullData)
            udpBuffer.removeValue(forKey: frameID)
        }

        if udpPacketsReceived % 100 == 0 {
            for (key, val) in udpBuffer {
                if val.time.timeIntervalSinceNow < -1.0 {
                    udpBuffer.removeValue(forKey: key)
                }
            }
        }
    }

    private func removeConnection(_ connection: NWConnection) {
        let connId = ObjectIdentifier(connection)
        DispatchQueue.main.async {
            self.connectedClients.removeAll(where: { $0 === connection })
            self.connectionFormat.removeValue(forKey: connId)
            // Do NOT reset wirelessADBEnabled — once enabled, it stays enabled
            // to prevent re-running adb tcpip 5555 on every reconnect
            guard !self.isStopped else { return }
            if self.connectedClients.isEmpty && self.lastADBPort != nil {
                self.startReconnectTimer()
            }
        }
    }

    private func startReconnectTimer() {
        guard !isReconnecting, !isStopped else { return }
        isReconnecting = true
        reconnectAttempts = 0
        stopReconnectTimer()
        LogManager.shared.log("Receiver: Connection lost. Will auto-reconnect via ADB...")
        DispatchQueue.main.async {
            self.status = "Reconnecting via ADB..."
        }

        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.attemptADBReconnect()
        }
        attemptADBReconnect()
    }

    private func stopReconnectTimer() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
    }

    private func attemptADBReconnect() {
        guard let port = lastADBPort, !isStopped else { return }

        reconnectAttempts += 1
        if reconnectAttempts > Self.maxReconnectAttempts {
            stopReconnectTimer()
            isReconnecting = false
            LogManager.shared.log("Receiver: ADB auto-reconnect failed after \(Self.maxReconnectAttempts) attempts")
            DispatchQueue.main.async {
                self.status = "Reconnect failed. Tap 'Connect via ADB' to retry."
            }
            return
        }

        LogManager.shared.log("Receiver: ADB reconnect attempt \(reconnectAttempts)/\(Self.maxReconnectAttempts)")
        DispatchQueue.main.async {
            self.status = "Reconnecting via ADB (\(self.reconnectAttempts)/\(Self.maxReconnectAttempts))..."
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

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
                    return
                }
                adb = found
            }

            let deviceSerial = self.findADBDevice(adb: adb)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: adb)
            var args: [String] = []
            if let serial = deviceSerial {
                args += ["-s", serial]
            }
            let localPort = port + 1
            args += ["forward", "tcp:\(localPort)", "tcp:\(port)"]
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                process.waitUntilExit()

                if process.terminationStatus == 0 {
                    self.lastADBPath = adb
                    self.lastADBSerial = deviceSerial
                    self.lastADBLocalPort = localPort

                    let injector = ADBInputInjector(adbPath: adb, deviceSerial: deviceSerial)
                    DispatchQueue.main.async {
                        self.adbInputInjector = injector
                        self.isReconnecting = false
                        self.reconnectAttempts = 0
                        self.stopReconnectTimer()
                    }
                    self.connectTo(host: "localhost", port: localPort)
                }
            } catch {
                LogManager.shared.log("Receiver: ADB reconnect error: \(error)")
            }
        }
    }

    // MARK: - VideoDecoderDelegate

    func didDecode(sampleBuffer: CMSampleBuffer) {
        DispatchQueue.main.async {
            self.videoRenderer?.enqueue(sampleBuffer)
        }
    }

    func sendInputEvent(_ event: InputEvent) {
        if event.type != .command {
            adbInputInjector?.inject(event)
        }

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
                    connection.send(content: packet, completion: .contentProcessed { _ in })
                }
            }
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
            if let match = output.range(of: #"(\d+)x(\d+)"#, options: .regularExpression) {
                let sizeStr = String(output[match])
                let parts = sizeStr.split(separator: "x")
                if parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) {
                    self.screenWidth = w
                    self.screenHeight = h
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
                runADB(["shell", "input", "tap", "\(px)", "\(py)"])
            }
        case .scrollWheel:
            let now = Date()
            guard now.timeIntervalSince(lastScrollTime) > 0.3 else { return }
            lastScrollTime = now
            let swipeDistance = 200
            let dy = event.deltaY > 0 ? -swipeDistance : swipeDistance
            let endY = min(max(py + dy, 0), screenHeight)
            runADB(["shell", "input", "swipe", "\(px)", "\(py)", "\(px)", "\(endY)", "100"])
        case .keyDown:
            if let androidKey = macToAndroidKeyCode(event.keyCode) {
                runADB(["shell", "input", "keyevent", "\(androidKey)"])
            }
        case .rightMouseDown:
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
        switch macKey {
        case 36: return 66   // Return
        case 51: return 67   // Delete
        case 53: return 4    // Escape -> Back
        case 48: return 61   // Tab
        case 49: return 62   // Space
        case 123: return 21  // Left
        case 124: return 22  // Right
        case 125: return 20  // Down
        case 126: return 19  // Up
        case 115: return 122 // Home
        case 119: return 123 // End
        case 116: return 92  // Page Up
        case 121: return 93  // Page Down
        case 72: return 24   // Volume Up
        case 73: return 25   // Volume Down
        default: return nil
        }
    }
}
