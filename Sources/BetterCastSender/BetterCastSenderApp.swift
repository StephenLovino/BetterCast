import SwiftUI
import Network

@main
struct BetterCastSenderApp: App {
    @StateObject private var networkClient = NetworkClient()

    var body: some Scene {
        WindowGroup {
            VStack {
                Text("BetterCast Sender")
                    .font(.largeTitle)
                    .padding()
                
                Text("Status: \(networkClient.status)")
                    .foregroundStyle(.gray)
                    .padding()
                
                List(networkClient.foundServices, id: \.name) { service in
                    HStack {
                        Text(service.name)
                        Spacer()
                        if networkClient.connectedService?.name == service.name {
                            Text("Connected").foregroundStyle(.green)
                        } else {
                            Button("Connect") {
                                networkClient.connect(to: service)
                            }
                        }
                    }
                }
                
                Divider()
                
                SettingsView(client: networkClient)
                    .padding()
                
                Spacer()
                LogView()
            }
            .frame(minWidth: 500, minHeight: 600)
            .onAppear {
                networkClient.startBrowsing()
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var client: NetworkClient
    
    var body: some View {
        Form {
            Section(header: Text("Virtual Display Settings")) {
                Toggle("Use Virtual Display", isOn: $client.useVirtualDisplay)
                
                Picker("Resolution", selection: $client.selectedResolution) {
                    ForEach(VirtualDisplayManager.defaultResolutions, id: \.self) { res in
                        Text(res.name).tag(res)
                    }
                }
                .disabled(!client.useVirtualDisplay)
                
                Toggle("Retina Mode (HiDPI)", isOn: $client.isRetina)
                    .disabled(!client.useVirtualDisplay)
            }
            
            Section(header: Text("Connection")) {
                Picker("Type", selection: $client.connectionType) {
                    Text("TCP (Reliable)").tag("TCP")
                    Text("UDP (Fast)").tag("UDP")
                }
                
                Picker("Quality", selection: $client.selectedQuality) {
                    ForEach(StreamQuality.allCases) { quality in
                        Text(quality.name).tag(quality)
                    }
                }
                .disabled(client.isConnected && client.status.contains("Connected")) 
                // We could allow dynamic bitrate change, but swapping encoder requires re-init. Start simpler.
                
                if client.isConnected {
                     HStack {
                         Text("Transfer Speed")
                         Spacer()
                         Text(client.transferRate)
                             .foregroundStyle(.green)
                     }
                }
            }
            
            Button("Apply & Restart Stream") {
                if let service = client.connectedService {
                    // Full Reconnect to fix "Connection Refused" bug on UDP
                    client.disconnect()
                    
                    // Wait a moment for socket tear down then reconnect
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        client.connect(to: service)
                    }
                }
            }
        }
    }
}

struct DiscoveredService: Identifiable {
    let id = UUID()
    let name: String
    let endpoint: NWEndpoint
}

enum StreamQuality: Int, CaseIterable, Identifiable {
    case low = 5_000_000
    case medium = 10_000_000
    case high = 20_000_000
    case ultra = 50_000_000
    
    var id: Int { self.rawValue }
    var name: String {
        switch self {
        case .low: return "Low (5 Mbps)"
        case .medium: return "Medium (10 Mbps)"
        case .high: return "High (20 Mbps)"
        case .ultra: return "Ultra (50 Mbps)"
        }
    }
}

class NetworkClient: ObservableObject, VideoEncoderDelegate {
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var screenRecorder: ScreenRecorder?
    private var videoEncoder: VideoEncoder?
    private var virtualDisplayManager: VirtualDisplayManager?
    
    @Published var status: String = "Idle"
    @Published var foundServices: [DiscoveredService] = []
    @Published var connectedService: DiscoveredService?
    @Published var useVirtualDisplay: Bool = true // Toggle between mirroring and extended display
    
    // Fragmentation State
    private var udpFrameId: UInt32 = 0
    
    // Transfer Stats
    @Published var transferRate: String = "0 Mbps"
    private var bytesSentWindow: Int = 0
    private var lastStatsTime: Date = Date()
    
    // Settings
    @Published var selectedResolution: VirtualDisplayManager.Resolution = VirtualDisplayManager.defaultResolutions[0]
    @Published var isRetina: Bool = false
    @Published var connectionType: String = "TCP" {
        didSet {
            // Restart browsing if type changes
            browser?.cancel()
            startBrowsing()
        }
    }
    
    @Published var selectedQuality: StreamQuality = .high
    
    var isConnected: Bool { connection != nil }


    func startBrowsing() {
        let isUDP = (connectionType == "UDP")
        let parameters: NWParameters
        
        if isUDP {
            parameters = NWParameters.udp
        } else {
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.enableKeepalive = true
            parameters = NWParameters(tls: nil, tcp: tcpOptions)
        }
        parameters.includePeerToPeer = true
        
        // Scan for the appropriate service type
        let type = isUDP ? "_bettercast._udp" : "_bettercast._tcp"
        LogManager.shared.log("Sender: Browsing for \(type)...")
        
        let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: parameters)
        self.browser = browser
        
        browser.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    self?.status = "Browsing (\(self?.connectionType ?? "?"))..."
                case .failed(let error):
                    self?.status = "Browsing failed: \(error.localizedDescription)"
                default:
                    break
                }
            }
        }
        
        browser.browseResultsChangedHandler = { [weak self] results, changes in
            DispatchQueue.main.async {
                // If we are currently connected, do NOT overwrite the specific service we are connected to.
                // Just update the list.
                self?.foundServices = results.compactMap { result in
                    if case .service(let name, _, _, _) = result.endpoint {
                        return DiscoveredService(name: name, endpoint: result.endpoint)
                    }
                    return nil
                }
            }
        }
        
        browser.start(queue: .main)
    }
    
    func connect(to service: DiscoveredService) {
        // Disconnect previous first
        if connection != nil {
            disconnect()
        }
        
        self.status = "Connecting to \(service.name) (\(connectionType))..."
        
        let isUDP = (connectionType == "UDP")
        let parameters: NWParameters
        
        if isUDP {
            parameters = NWParameters.udp
        } else {
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.enableKeepalive = true
            parameters = NWParameters(tls: nil, tcp: tcpOptions)
        }
        parameters.includePeerToPeer = true
        
        let connection = NWConnection(to: service.endpoint, using: parameters)
        self.connection = connection
        
        connection.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    self?.status = "Connected to \(service.name)"
                    self?.connectedService = service
                    self?.startStreaming()
                    self?.receive(on: connection) // Start listening for input events
                    self?.startStatsTimer()
                case .failed(let error):
                    self?.status = "Connection failed: \(error.localizedDescription)"
                    LogManager.shared.log("Sender: Connection failed \(error)")
                    self?.connectedService = nil
                    self?.stopStreaming()
                case .waiting(let error):
                    self?.status = "Waiting... \(error.localizedDescription)"
                default:
                    break
                }
            }
        }
        
        connection.start(queue: .main)
    }
    
    func disconnect() {
        stopStreaming()
        connection?.cancel()
        connection = nil
        connectedService = nil
        status = "Disconnected"
    }
    
    private func startStatsTimer() {
        // Simple timer to update transfer rate UI
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            if self.connection == nil { timer.invalidate(); return }
            
            let bytes = self.bytesSentWindow
            self.bytesSentWindow = 0
            
            let mbps = Double(bytes * 8) / 1_000_000.0
            self.transferRate = String(format: "%.1f Mbps", mbps)
        }
    }
    
    private func receive(on connection: NWConnection) {
         if connectionType == "UDP" {
             receiveUDP(on: connection)
         } else {
             receiveTCP(on: connection)
         }
    }
    
    private func receiveTCP(on connection: NWConnection) {
        // Read 4-byte length
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] content, contentContext, isComplete, error in
            if let error = error {
                LogManager.shared.log("Sender: Receive error \(error)")
                return
            }
            
            if let content = content, content.count == 4 {
                let length = content.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
                let bodyLength = Int(length)
                
                connection.receive(minimumIncompleteLength: bodyLength, maximumLength: bodyLength) { body, bodyContext, isComplete, error in
                    if let body = body {
                        // Decode InputEvent
                        if let event = try? JSONDecoder().decode(InputEvent.self, from: body) {
                            InputHandler.shared.handle(event: event)
                        }
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
             if let error = error {
                 LogManager.shared.log("Sender: Receive UDP error \(error)")
                 return
             }
             if let content = content {
                 if content.count > 4 {
                     let body = content.subdata(in: 4..<content.count)
                     if let event = try? JSONDecoder().decode(InputEvent.self, from: body) {
                         InputHandler.shared.handle(event: event)
                     }
                 }
             }
             self?.receiveUDP(on: connection)
        }
    }
    
     func startStreaming() {
        LogManager.shared.log("Sender: Starting Screen Capture & Encoding...")
        
        var targetDisplayID: CGDirectDisplayID? = nil
        
        // Create virtual display if enabled
        if useVirtualDisplay {
            LogManager.shared.log("Sender: Creating virtual display for extended desktop...")
            let displayManager = VirtualDisplayManager()
            
            // Override with UI settings
            let res = selectedResolution
            let resolution = VirtualDisplayManager.Resolution(
                width: res.width,
                height: res.height,
                ppi: isRetina ? min(220, res.ppi * 2) : res.ppi, 
                hiDPI: isRetina,
                name: "BetterCast Retina Display"
            )
            
            if let displayID = displayManager.createDisplay(resolution: resolution) {
                targetDisplayID = displayID
                virtualDisplayManager = displayManager
                
                // Update Input Handler with new display bounds
                // Add specific delay to ensure display is registered by WindowServer
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let bounds = CGDisplayBounds(displayID)
                    InputHandler.shared.updateDisplayBounds(bounds: bounds)
                    LogManager.shared.log("Sender: Virtual display bounds: \(bounds)")
                }
                
                LogManager.shared.log("Sender: Virtual display created with ID \(displayID)")
                LogManager.shared.log("Sender: Go to System Settings > Displays to arrange it")
            } else {
                LogManager.shared.log("Sender: Failed to create virtual display, using main screen (mirroring)")
            }
        } else {
            LogManager.shared.log("Sender: Using main screen (mirroring mode)")
        }
        
        // Calculate Physical Capture Resolution
        // If Retina Mode is enabled, we want to capture at 2x scale (e.g. 1920x1080 -> 3840x2160)
        let scale = isRetina ? 2 : 1
        let captureWidth = selectedResolution.width * scale
        let captureHeight = selectedResolution.height * scale
        
        LogManager.shared.log("Sender: Configuring Encoder/Capture for \(captureWidth)x\(captureHeight) (Scale: \(scale)x) @ \(selectedQuality.name)")
        
        let encoder = VideoEncoder(width: captureWidth, height: captureHeight, bitrate: selectedQuality.rawValue)
        encoder.delegate = self
        self.videoEncoder = encoder
        
        let recorder = ScreenRecorder(
            videoEncoder: encoder,
            targetDisplayID: targetDisplayID,
            width: captureWidth,
            height: captureHeight
        )
        self.screenRecorder = recorder
        
        Task {
            await recorder.startCapture()
        }
    }
    
     func stopStreaming() {
        LogManager.shared.log("Sender: Stopping streaming")
        screenRecorder?.stopCapture()
        screenRecorder = nil
        videoEncoder = nil
        
        // Clean up virtual display
        virtualDisplayManager?.destroyDisplay()
        virtualDisplayManager = nil
    }
    
        // Let's wrap EVERY send in a custom 4-byte length header for simplicity on the receiver side.
        // The receiver strictly reads 4 bytes, then N bytes.
        
    // VideoEncoderDelegate
    func videoEncoder(_ encoder: VideoEncoder, didEncode data: Data) {
        guard let connection = connection else { return }
        
        if connectionType == "UDP" {
            // UDP: Fragmentation Logic
            // Do NOT use TCP-style length framing. Reassembly handles the datagram.
            // Packet structure expected by Decoder: [NALU_Len][NALU]... (AVCC)
            // 'data' is already in this format.
            
            // Fragment packet if needed
            // Max safe payload usually 1400. Lowering to 1000 to be extremely safe against varying MTUs/Headers.
            let mtu = 1000 
            let headerSize = 8
            let maxPayload = mtu - headerSize
            
            udpFrameId &+= 1 // Allow overflow wrap
            let thisFrameId = udpFrameId
            
            let totalData = data // Use raw AVCC data, not wrapped
            let totalCount = totalData.count
            
            // Track bandwidth
            bytesSentWindow += totalCount
            
            let totalChunks = UInt16((totalCount + maxPayload - 1) / maxPayload)
            
            for chunkIndex in 0..<totalChunks {
                let start = Int(chunkIndex) * maxPayload
                let end = min(start + maxPayload, totalCount)
                let chunkData = totalData.subdata(in: start..<end)
                
                var header = Data()
                var fid = thisFrameId.bigEndian
                var cid = chunkIndex.bigEndian
                var tot = totalChunks.bigEndian
                
                header.append(Data(bytes: &fid, count: 4))
                header.append(Data(bytes: &cid, count: 2))
                header.append(Data(bytes: &tot, count: 2))
                
                var finalPacket = header
                finalPacket.append(chunkData)
                
                // Pacing: Micro-sleep to prevent flooding the network card/router buffer
                // 100 microseconds = 0.1ms. For a 40KB keyframe (40 packets), total delay is ~4ms.
                // This fits well within the 16ms frame budget (60fps).
                usleep(100) 
                
                connection.send(content: finalPacket, completion: .contentProcessed { error in
                    if let error = error {
                        LogManager.shared.log("Sender: UDP Chunk Error \(error)")
                    }
                })
            }
            
        } else {
            // TCP: Send as stream with Length Prefix (Framing)
            var packet = Data()
            var length32 = UInt32(data.count).bigEndian
            packet.append(Data(bytes: &length32, count: 4))
            packet.append(data)
            
            // Track bandwidth
            bytesSentWindow += packet.count
            
            connection.send(content: packet, completion: .contentProcessed { error in
                if let error = error {
                    print("Sender: Send error \(error)")
                    LogManager.shared.log("Sender: Send error \(error)")
                }
            })
        }
    }
}
