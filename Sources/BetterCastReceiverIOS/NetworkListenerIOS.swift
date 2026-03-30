#if canImport(UIKit)
import Foundation
import Network
import CoreMedia

protocol NetworkListenerDelegate: AnyObject {
    func networkListener(_ listener: NetworkListenerIOS, didUpdateStatus status: String)
    func networkListener(_ listener: NetworkListenerIOS, didReceiveInput event: InputEvent) // If we were receiving input
}

class NetworkListenerIOS {
    weak var delegate: NetworkListenerDelegate?
    
    private var tcpListener: NWListener?
    private var udpListener: NWListener?
    
    private var connectedClients: [NWConnection] = []
    
    // Dependencies
    weak var videoDecoder: VideoDecoder?
    weak var videoRenderer: VideoRendererIOS? // We will define this later
    
    private let networkQueue = DispatchQueue(label: "com.bettercast.network.ios", qos: .userInteractive)
    
    // UDP Reassembly
    private var udpBuffer: [UInt32: (total: Int, chunks: [UInt16: Data], time: Date)] = [:]
    private let udpLock = NSLock()
    private var lastDecodedFrameId: UInt32 = 0
    private var lastKeyframeRequest = Date.distantPast
    
    // Stats
    private var udpPacketsReceived = 0
    
    // Heartbeat
    private var heartbeatTimer: Timer?
    
    init() {}
    
    func setup(decoder: VideoDecoder, renderer: VideoRendererIOS) {
        self.videoDecoder = decoder
        self.videoRenderer = renderer
        decoder.delegate = self
    }
    
    func start() {
        startTCP()
        startUDP()
        startHeartbeat()
    }
    
    private static let knownPort: NWEndpoint.Port = 51820

    private func startTCP() {
        do {
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.enableKeepalive = true
            tcpOptions.noDelay = true
            let parameters = NWParameters(tls: nil, tcp: tcpOptions)
            parameters.includePeerToPeer = true
            parameters.serviceClass = .interactiveVideo

            // Bind to well-known port so non-Apple senders (Windows/Linux) can connect
            // reliably without depending on mDNS port resolution
            let listener: NWListener
            do {
                listener = try NWListener(using: parameters, on: Self.knownPort)
                LogManager.shared.log("ReceiverIOS (TCP): Bound to port \(Self.knownPort)")
            } catch {
                // Port in use — fall back to system-assigned port
                LogManager.shared.log("ReceiverIOS (TCP): Port \(Self.knownPort) unavailable, using system port")
                listener = try NWListener(using: parameters)
            }

            let deviceName = UIDevice.current.name
            listener.service = NWListener.Service(name: deviceName, type: "_bettercast._tcp")

            listener.stateUpdateHandler = { [weak self] state in
                self?.handleListenerState(state, type: "TCP")
            }

            listener.newConnectionHandler = { [weak self] connection in
                LogManager.shared.log("ReceiverIOS (TCP): New connection from \(connection.endpoint)")
                self?.handleNewConnection(connection, type: "TCP")
            }

            listener.start(queue: networkQueue)
            self.tcpListener = listener
        } catch {
            LogManager.shared.log("ReceiverIOS (TCP): Error \(error)")
        }
    }
    
    private func startUDP() {
        do {
            let parameters = NWParameters.udp
            parameters.includePeerToPeer = true
            
            let listener = try NWListener(using: parameters)
            let udpDeviceName = UIDevice.current.name
            listener.service = NWListener.Service(name: udpDeviceName, type: "_bettercast._udp")
            
            listener.stateUpdateHandler = { [weak self] state in
                self?.handleListenerState(state, type: "UDP")
            }
            
            listener.newConnectionHandler = { [weak self] connection in
                LogManager.shared.log("ReceiverIOS (UDP): New connection from \(connection.endpoint)")
                self?.handleNewConnection(connection, type: "UDP")
            }
            
            listener.start(queue: networkQueue)
            self.udpListener = listener
        } catch {
            LogManager.shared.log("ReceiverIOS (UDP): Error \(error)")
        }
    }
    
    private func handleListenerState(_ state: NWListener.State, type: String) {
        DispatchQueue.main.async {
            switch state {
            case .ready:
                if type == "TCP" {
                    self.delegate?.networkListener(self, didUpdateStatus: "Ready. Waiting for Sender...")
                }
                LogManager.shared.log("ReceiverIOS (\(type)): Ready")
            case .failed(let error):
                if type == "TCP" {
                     self.delegate?.networkListener(self, didUpdateStatus: "Failed: \(error.localizedDescription)")
                }
                LogManager.shared.log("ReceiverIOS (\(type)): Failed \(error)")
            default:
                break
            }
        }
    }
    
    private func handleNewConnection(_ connection: NWConnection, type: String) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                LogManager.shared.log("ReceiverIOS: \(type) Connection ready")
                DispatchQueue.main.async {
                    self.delegate?.networkListener(self, didUpdateStatus: "Connected via \(type)")
                }
                
                // Add to clients list safely
                // (Using a lock or simple check on queue)
                if !self.connectedClients.contains(where: { $0 === connection }) {
                    self.connectedClients.append(connection)
                }
                
                if type == "UDP" {
                    self.receiveUDP(on: connection)
                } else {
                    self.receiveTCP(on: connection)
                }
            case .failed(let error):
                LogManager.shared.log("ReceiverIOS: Connection failed \(error)")
                self.removeConnection(connection)
            case .cancelled:
                self.removeConnection(connection)
            default:
                break
            }
        }
        connection.start(queue: networkQueue)
    }
    
    private func removeConnection(_ connection: NWConnection) {
        if let index = connectedClients.firstIndex(where: { $0 === connection }) {
            connectedClients.remove(at: index)
        }
    }
    
    private func receiveTCP(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] content, contentContext, isComplete, error in
            if let error = error {
                LogManager.shared.log("ReceiverIOS (TCP): Error \(error)")
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
    
    private func receiveUDP(on connection: NWConnection) {
        connection.receiveMessage { [weak self] content, contentContext, isComplete, error in
            if let error = error { return }
            if let content = content, !content.isEmpty {
                 self?.handleUDPPacket(content)
            }
            self?.receiveUDP(on: connection)
        }
    }
    
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
        
        if udpBuffer[frameID] == nil {
            udpBuffer[frameID] = (total: Int(totalChunks), chunks: [:], time: Date())
        }
        
        udpBuffer[frameID]?.chunks[chunkID] = payload
        
        if let entry = udpBuffer[frameID], entry.chunks.count == entry.total {
            
            // Gap Detection
            let diff = Int(frameID) - Int(lastDecodedFrameId)
            if diff > 1 && diff < 1000 {
                 // v62: Relaxed throttle to 2.0s
                 if Date().timeIntervalSince(lastKeyframeRequest) > 2.0 {
                     LogManager.shared.log("ReceiverIOS: Gap Detected. Requesting IDR.")
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
            
            // Aggressive cleanup to prevent memory buildup on iOS
            udpPacketsReceived += 1
            if udpPacketsReceived % 30 == 0 || udpBuffer.count > 10 {
                 for (key, val) in udpBuffer {
                    if val.time.timeIntervalSinceNow < -0.5 {
                        udpBuffer.removeValue(forKey: key)
                    }
                }
            }
        }
    }
    
    private func startHeartbeat() {
        LogManager.shared.log("ReceiverIOS: Starting heartbeat timer (0.5s interval)")
        DispatchQueue.main.async { [weak self] in
            self?.heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.sendHeartbeat()
            }
        }
    }
    
    private func sendHeartbeat() {
        LogManager.shared.log("ReceiverIOS: Sending heartbeat (keyCode 888)")
        // Send a simple heartbeat message (empty input event with type .command and keyCode 888)
        let heartbeat = InputEvent(
            type: .command,
            keyCode: 888 // Special code for heartbeat
        )
        sendInputEvent(heartbeat)
    }
    
    func sendInputEvent(_ event: InputEvent) {
        // v61 Reliability: 3x for critical events
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

// Conformance to VideoDecoderDelegate
extension NetworkListenerIOS: VideoDecoderDelegate {
    func didDecode(sampleBuffer: CMSampleBuffer) {
        DispatchQueue.main.async {
            self.videoRenderer?.enqueue(sampleBuffer)
        }
    }
}
#endif

