import SwiftUI
import Network
import CoreMedia
import AppKit

@main
struct BetterCastReceiverApp: App {
    // Create dependencies at top level to observe them
    @StateObject private var videoDecoder = VideoDecoder()
    @StateObject private var networkListener = NetworkListener()
    @StateObject private var videoRenderer = VideoRenderer()
    
    // Bridge network listener to renderer via a decoder
    // Since App struct is created once, we need a coordinator or ViewModel.
    // networkListener is already an ObservableObject. Let's make it own the decoder logic or bridge it.
    
    var body: some Scene {
        WindowGroup {
            ZStack {
                // Video Layer
                GeometryReader { geometry in
                    VideoRendererView(renderer: videoRenderer)
                        .onAppear {
                            videoRenderer.layout()
                        }
                        .onChange(of: geometry.size) { _ in
                           videoRenderer.layout()
                        }
                        .edgesIgnoringSafeArea(.all) // Fix for "Dark Space" / Full Screen coverage
                }
                
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
                Button("Save Logs...") {
                   saveLogs()
                }
                .keyboardShortcut("s", modifiers: .command)
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

class NetworkListener: ObservableObject, VideoDecoderDelegate {
    private var tcpListener: NWListener?
    private var udpListener: NWListener?
    
    @Published var status: String? = "Initializing..."
    @Published var connectedClients: [NWConnection] = []
    
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
    }
    
    private func startTCP() {
        do {
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.enableKeepalive = true
            let parameters = NWParameters(tls: nil, tcp: tcpOptions)
            parameters.includePeerToPeer = true
            
            let listener = try NWListener(using: parameters)
            listener.service = NWListener.Service(name: "BetterCast Receiver", type: "_bettercast._tcp")
            
            listener.stateUpdateHandler = { [weak self] state in
                self?.handleListenerState(state, type: "TCP")
            }
            
            listener.newConnectionHandler = { [weak self] connection in
                LogManager.shared.log("Receiver (TCP): New connection from \(connection.endpoint)")
                self?.handleNewConnection(connection, isUDP: false)
            }
            
            listener.start(queue: .main)
            self.tcpListener = listener
        } catch {
            LogManager.shared.log("Receiver (TCP): Error \(error)")
        }
    }
    
    private func startUDP() {
        do {
            let parameters = NWParameters.udp
            parameters.includePeerToPeer = true
            
            let listener = try NWListener(using: parameters)
            listener.service = NWListener.Service(name: "BetterCast Receiver UDP", type: "_bettercast._udp")
            
            listener.stateUpdateHandler = { [weak self] state in
                self?.handleListenerState(state, type: "UDP")
            }
            
            listener.newConnectionHandler = { [weak self] connection in
                LogManager.shared.log("Receiver (UDP): New connection from \(connection.endpoint)")
                self?.handleNewConnection(connection, isUDP: true)
            }
            
            listener.start(queue: .main)
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
    
    private func handleNewConnection(_ connection: NWConnection, isUDP: Bool) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                LogManager.shared.log("Receiver: \(isUDP ? "UDP" : "TCP") Connection ready")
                DispatchQueue.main.async {
                    if let self = self {
                        // For UDP, we might have multiple streams or just one per client?
                        // Just append for now so we can send input back via TCP potentially?
                        // Actually, for Input Back channel, we probably prefer TCP (Reliable).
                        // If this connection is UDP, we maybe shouldn't add it to 'connectedClients' used for Input?
                        // Or we can send Input over UDP too? UDP input is fine (mouse movements). Key clicks maybe better TCP.
                        // Let's treat them equal for now.
                        if !self.connectedClients.contains(where: { $0 === connection }) {
                            self.connectedClients.append(connection)
                        }
                    }
                }
                if isUDP {
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
        connection.start(queue: .main)
    }
    
    private func receiveTCP(on connection: NWConnection) {
        // TCP: Expect 4-byte length prefix
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
    
    private func handleUDPPacket(_ data: Data) {
        guard data.count > 8 else { return } // Min header size
        
        let header = data.prefix(8)
        let payload = data.dropFirst(8)
        
        let frameID = header.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self).bigEndian }
        let chunkID = header.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt16.self).bigEndian }
        let totalChunks = header.withUnsafeBytes { $0.load(fromByteOffset: 6, as: UInt16.self).bigEndian }
        
        udpLock.lock()
        defer { udpLock.unlock() }
        
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
            // LogManager.shared.log("Receiver: Start Frame \(frameID)")
        }
        
        udpBuffer[frameID]?.chunks[chunkID] = payload
        
        if let entry = udpBuffer[frameID], entry.chunks.count == entry.total {
            udpFramesReassembled += 1
            
            // Reassembly complete
            let sortedChunks = entry.chunks.sorted { $0.key < $1.key }
            var fullData = Data()
            for (_, chunkData) in sortedChunks {
                fullData.append(chunkData)
            }
            
            self.videoDecoder?.decode(data: fullData)
            udpBuffer.removeValue(forKey: frameID)
            
        } else {
             // Incomplete
             udpFramesIncomplete = udpBuffer.count // Rough metric of pending frames
        }
        
        // Periodic Cleanup (every 100 packets roughly to avoid heavy scan)
        if udpPacketsReceived % 100 == 0 {
             for (key, val) in udpBuffer {
                if val.time.timeIntervalSinceNow < -1.0 { // Faster cleanup (1s)
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
    
    func didDecode(sampleBuffer: CMSampleBuffer) {
        DispatchQueue.main.async {
            self.videoRenderer?.enqueue(sampleBuffer)
        }
    }
    
    func sendInputEvent(_ event: InputEvent) {
        // Encode event
        guard let data = try? JSONEncoder().encode(event) else { return }
        
        // Wrap with length header for TCP compatibility (UDP ignores it or treats as payload? No, receiver logic depends on it)
        // Wait, if we send Input BACK to Sender.
        // If connected via UDP, can we send reliable Input?
        // UDP is unreliable. Input events (clicks) MUST be reliable.
        // STRATEGY: Receive Video via UDP (Fast), Send Input via TCP (Reliable).
        // BUT, if we only have a UDP connection open...
        // For this v1 implementation: If connected via UDP, we send input via UDP.
        // It might be lossy. Mouse move is okay. Clicks might be lost.
        // Ideal: Parallel TCP connection for control.
        // Simplification: Just send it. Mouse feedback is immediate so user will click again.
        
        var packet = Data()
        var length32 = UInt32(data.count).bigEndian
        packet.append(Data(bytes: &length32, count: 4))
        packet.append(data)
        
        for connection in connectedClients {
            connection.send(content: packet, completion: .contentProcessed { error in
                if let error = error {
                    LogManager.shared.log("Receiver: Send Input Error \(error)")
                }
            })
        }
    }
}
