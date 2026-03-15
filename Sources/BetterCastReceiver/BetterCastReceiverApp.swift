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
                
                // UI Overlay
                VStack {
                    if networkListener.connectedClients.isEmpty {
                        Text("Waiting for connection...")
                            .foregroundStyle(.orange)
                            .padding()
                            .background(.black.opacity(0.5))
                            .cornerRadius(8)
                    }
                    
                    Spacer()
                }
                .padding()
            }
            .frame(minWidth: 800, minHeight: 600)
            .background(Color.black) // Ensure black background for letterboxing
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
}

class NetworkListener: ObservableObject, VideoDecoderDelegate {
    private var tcpListener: NWListener?
    private var udpListener: NWListener?
    private var quicListener: NWListener?
    
    @Published var status: String? = "Initializing..."
    @Published var connectedClients: [NWConnection] = []
    
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
    
    private func startHeartbeat() {
        // v69 Heartbeat
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let keepalive = Data([0xDE, 0xAD, 0xBE, 0xEF])
            
            for connection in self.connectedClients {
                connection.send(content: keepalive, completion: .contentProcessed({ _ in }))
            }
        }
    }
    
    private func startTCP() {
        do {
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.enableKeepalive = true
            let parameters = NWParameters(tls: nil, tcp: tcpOptions)
            parameters.includePeerToPeer = true
            parameters.allowLocalEndpointReuse = true
            // parameters.requiredInterfaceType = .wifi <--- REMOVED: Allow AWDL!
            parameters.serviceClass = .responsiveData
            
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
        // Reliability for UDP:
        // Clicks and Key Presses are critical. If 1 packet drops, user is stuck.
        // Send them 3 times.
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
