import SwiftUI
import Network
import Security
import ScreenCaptureKit


@main
struct BetterCastSenderApp: App {
    @StateObject private var networkClient = NetworkClient()

    var body: some Scene {
        WindowGroup {
            ScrollView {
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
                            if networkClient.connectedServices.contains(where: { $0.name == service.name }) {
                                HStack {
                                    Text("Connected").foregroundStyle(.green)
                                    Button("Disconnect") {
                                        networkClient.disconnectService(service)
                                    }
                                    .foregroundStyle(.red)
                                }
                            } else {
                                Button("Connect") {
                                    networkClient.connect(to: service)
                                }
                            }
                        }
                    }
                    .frame(height: 150) // Restrict list height to prevent it expanding too much
                    
                    Divider()
                    
                    SettingsView(client: networkClient)
                        .padding()
                    
                    Spacer()
                    LogView()
                        .frame(height: 100)
                }
                .padding()
            }
            .frame(minWidth: 500, minHeight: 700)
            .onAppear {
                // 1. Prioritize Screen Recording Permission (Critical for Streaming)
                networkClient.checkScreenRecordingPermission()
                
                // 2. Start Network
                networkClient.startBrowsing()
                
                // 3. Delay Accessibility Check (Secondary) so Screen Recording prompt appears first if needed
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                     InputHandler.shared.checkAccessibility()
                }
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
                Picker("Connection Mode", selection: $client.interfacePreference) {
                     ForEach(NetworkInterfacePreference.allCases) { pref in
                         Text(pref.rawValue).tag(pref)
                     }
                }
                .disabled(client.isConnected) 
                
                Picker("Type", selection: $client.connectionType) {
                    Text("TCP (Reliable)").tag("TCP")
                    Text("UDP (Fast)").tag("UDP")
                }
                
                Picker("Quality", selection: $client.selectedQuality) {
                    ForEach(StreamQuality.allCases) { quality in
                        Text(quality.name).tag(quality)
                    }
                }
                
                if client.isConnected {
                     HStack {
                         Text("Transfer Speed")
                         Spacer()
                         Text(client.transferRate)
                             .foregroundStyle(.green)
                     }
                }
            }
            
            Section(header: Text("Troubleshooting & Controls")) {
                Button("Reset Screen Recording Permissions (Popup) 🔒") {
                    client.resetScreenCapturePermissions()
                }
                .foregroundStyle(.orange)
                .help("Resets the system decision, forcing the 'Allow BetterCast to record screen?' popup to appear again on restart.")
                
                HStack {
                    Button("Restart App 🔄") {
                        client.restartApp()
                    }
                    Button("Force Quit ❌") {
                        client.quitApp()
                    }
                }
            }
            
            Button("Apply Settings & Update Stream") {
                if client.isConnected {
                    // Smart Update
                     client.updateStreamResolution()
                } else {
                    // Just Restart Browsing/Connect logic handled by state
                }
            }
            .disabled(!client.isConnected) // Only useful if connected to restart the stream with new settings
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
    case extreme = 100_000_000
    
    var id: Int { self.rawValue }
    var name: String {
        switch self {
        case .low: return "Low (5 Mbps)"
        case .medium: return "Medium (10 Mbps)"
        case .high: return "High (20 Mbps)"
        case .ultra: return "Ultra (50 Mbps)"
        case .extreme: return "Extreme (100 Mbps)"
        }
    }
}

enum NetworkInterfacePreference: String, CaseIterable, Identifiable {
    case auto = "Auto (Apple Default)"
    case p2pOnly = "Force P2P (WiFi Direct)"
    case routerOnly = "Force Router/WiFi"
    case wiredCable = "USB / Thunderbolt Cable"

    var id: String { self.rawValue }
}

// Connection tracking for multi-display
struct ConnectionInfo {
    let id: UUID
    let connection: NWConnection
    let service: DiscoveredService
    var lastHeartbeat: Date
}

class NetworkClient: ObservableObject, VideoEncoderDelegate {
    private var browser: NWBrowser?
    private var connections: [UUID: ConnectionInfo] = [:]
    private var screenRecorder: ScreenRecorder?
    private var videoEncoder: VideoEncoder?
    private var virtualDisplayManager: VirtualDisplayManager?

    @Published var status: String = "Idle"
    @Published var foundServices: [DiscoveredService] = []
    @Published var connectedServices: [DiscoveredService] = []
    @Published var useVirtualDisplay: Bool = true // Toggle between mirroring and extended display

    // Input event deduplication (receiver sends critical events 3x over UDP for reliability)
    private var recentEventIds: Set<UInt64> = []
    private var recentEventIdQueue: [UInt64] = [] // FIFO to cap set size
    private let maxRecentEvents = 200

    private func isDuplicateEvent(_ eventId: UInt64) -> Bool {
        if recentEventIds.contains(eventId) {
            return true
        }
        recentEventIds.insert(eventId)
        recentEventIdQueue.append(eventId)
        if recentEventIdQueue.count > maxRecentEvents {
            let old = recentEventIdQueue.removeFirst()
            recentEventIds.remove(old)
        }
        return false
    }

    // Fragmentation State
    private var udpFrameId: UInt32 = 0
    
    // Transfer Stats
    @Published var transferRate: String = "0 Mbps"
    private var bytesSentWindow: Int = 0
    private var lastStatsTime: Date = Date()
    
    // Settings
    @Published var selectedResolution: VirtualDisplayManager.Resolution = VirtualDisplayManager.defaultResolutions[0]
    @Published var isRetina: Bool = false
    @Published var connectionType: String = "UDP" {
        didSet {
            // Restart browsing if type changes
            browser?.cancel()
            startBrowsing()
        }
    }
    
    @Published var selectedQuality: StreamQuality = .high
    
    // v67: Manual Interface Toggle
    @Published var interfacePreference: NetworkInterfacePreference = .p2pOnly
    
    var isConnected: Bool { !connections.isEmpty }


    func startBrowsing() {
        // Browsing params should match connection params ideally to filter results,
        // but often we want to SEE everything even if we can't connect.
        // For now, let's keep browsing "Auto" (responsiveData) but Connect strictly.
        // Actually, if we force P2P, we should probably browse P2P.
        
        let typeVal: String
        let parameters: NWParameters
        
         switch connectionType {
        case "UDP":
            typeVal = "_bettercast._udp"
            parameters = NWParameters.udp
        default: // TCP
            typeVal = "_bettercast._tcp"
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.enableKeepalive = true
            parameters = NWParameters(tls: nil, tcp: tcpOptions)
        }
        
        configureParameters(parameters) // Apply user pref
        
        // Scan for the appropriate service type
        LogManager.shared.log("Sender: Browsing for \(typeVal)...")
        
        let browser = NWBrowser(for: .bonjour(type: typeVal, domain: nil), using: parameters)
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
    
    // v69: Heartbeat
    private var lastHeartbeatTime: Date = Date()
    private var heartbeatTimer: Timer?
    private var connectionRefusedCount: Int = 0
    
    // v70: Hard-Lock AWDL Logic
    private let interfaceMonitor = NWPathMonitor()
    private var cachedAWDLInterface: NWInterface?
    private var cachedInfraInterface: NWInterface?
    
    init() {
        LogManager.shared.log("Sender: App Starting - Version v80 (Sync)")
        
        // We can't monitor recursively in init easily, but we can start it.
        interfaceMonitor.pathUpdateHandler = { [weak self] path in
            for interface in path.availableInterfaces {
                // Cache AWDL
                if interface.name.contains("awdl") || interface.name.contains("llw") {
                    let isNew = (self?.cachedAWDLInterface == nil)
                    self?.cachedAWDLInterface = interface
                    
                    if isNew {
                         LogManager.shared.log("Network: Found P2P Interface: \(interface.name) (\(interface.type))")
                         // v76 Critical Fix: Restart Browsing ON this interface to ensure we get the Link-Local Address!
                         // If we don't, we might try to connect to the Router IP via AWDL, which fails.
                         if self?.interfacePreference == .p2pOnly {
                             LogManager.shared.log("Network: Restarting Browser to force discovery via \(interface.name)...")
                             self?.startBrowsing()
                         }
                    }
                }
                // Cache Infra WiFi (en0 typically)
                if interface.type == .wifi && !interface.name.contains("awdl") && !interface.name.contains("llw") {
                     self?.cachedInfraInterface = interface
                     LogManager.shared.log("Network: Found Infra Interface: \(interface.name) (\(interface.type))")
                }
            }
        }
        interfaceMonitor.start(queue: .global())
    }

    private func configureParameters(_ parameters: NWParameters) {
        parameters.includePeerToPeer = true // Always allow discovery at least
        
        // v76 Update: Use cached AWDL if available (especially for Browser)
        if interfacePreference == .p2pOnly, let awdl = cachedAWDLInterface {
             LogManager.shared.log("Parameters: Binding to P2P Interface \(awdl.name) ✅")
             parameters.requiredInterface = awdl
             parameters.serviceClass = .interactiveVideo
             parameters.prohibitedInterfaceTypes = [.loopback, .wiredEthernet]
             return // Skip the rest
        }
        
        switch interfacePreference {
        case .auto:
            parameters.requiredInterfaceType = .wifi
            parameters.serviceClass = .responsiveData
            parameters.prohibitedInterfaceTypes = []
            
        case .p2pOnly:
             // v70: Direct Binding to AWDL Interface
             if let awdl = cachedAWDLInterface {
                 LogManager.shared.log("Sender: Hard-Locking to Interface: \(awdl.name) ✅")
                 parameters.requiredInterface = awdl
                 // Since we require a specific interface, prohibited list is irrelevant/redundant
             } else {
                 LogManager.shared.log("Sender: AWDL Interface not found yet. Falling back to Prohibition Strategy (Banning Infra). ⚠️")
                 
                 // v73: "Ban the Interface Object" directly, NOT the type.
                 if let infra = cachedInfraInterface {
                      LogManager.shared.log("Sender: Banning Infra Interface: \(infra.name) 🚫")
                      parameters.prohibitedInterfaces = [infra]
                 } else {
                      LogManager.shared.log("Sender: Infra Interface not found either? Falling back to Type prohibition (Risky).")
                      // If we can't find en0 object, we can't ban it specifically. 
                      // Fallback to banning Wired/Loopback only.
                 }
                 
                 parameters.serviceClass = .interactiveVideo
             }
             
             // Always ban these types
             parameters.prohibitedInterfaceTypes = [.loopback, .wiredEthernet]
             parameters.preferNoProxies = true
            
        case .routerOnly:
            parameters.serviceClass = .bestEffort
            parameters.prohibitedInterfaceTypes = [.loopback]
            // Allow standard routing

        case .wiredCable:
            // USB-C / Thunderbolt Bridge / Ethernet cable direct connection
            // Thunderbolt Bridge appears as .other (bridge0), Ethernet as .wiredEthernet
            // Ban WiFi and AWDL to force traffic over cable only
            parameters.serviceClass = .interactiveVideo
            parameters.prohibitedInterfaceTypes = [.loopback, .wifi]
            parameters.includePeerToPeer = false // No AWDL needed for cable
            parameters.preferNoProxies = true
            LogManager.shared.log("Parameters: Wired/Cable mode - WiFi/P2P disabled, using Ethernet/Thunderbolt Bridge")
        }
    }
    
    func connect(to service: DiscoveredService) {
        // Check if already connected to this service
        if connectedServices.contains(where: { $0.name == service.name }) {
            LogManager.shared.log("Sender: Already connected to \(service.name)")
            return
        }
        
        let deviceCount = connections.count + 1
        self.status = "Connecting to \(service.name) (Device #\(deviceCount))..."
        
        let parameters: NWParameters
        switch connectionType {
        case "UDP":
            parameters = NWParameters.udp
        default: // TCP
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.enableKeepalive = true
            tcpOptions.noDelay = true // Keep our optimization
            parameters = NWParameters(tls: nil, tcp: tcpOptions)
        }
        
        configureParameters(parameters)
        LogManager.shared.log("Sender: Connecting with Pref: \(interfacePreference.rawValue)")
        
        // v70: Update Browser params too? No, usually not needed for connection.
        
        let connection = NWConnection(to: service.endpoint, using: parameters)
        let connectionId = UUID()
        
        connection.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    // Add to connections dictionary
                    let info = ConnectionInfo(
                        id: connectionId,
                        connection: connection,
                        service: service,
                        lastHeartbeat: Date()
                    )
                    self?.connections[connectionId] = info
                    self?.connectedServices.append(service)
                    
                    let count = self?.connections.count ?? 0
                    self?.status = "Connected to \(count) device(s)"
                    LogManager.shared.log("Sender: Connected to \(service.name) (Total: \(count))")
                    
                    // Start streaming if this is first connection
                    if count == 1 {
                        self?.startStreaming()
                        self?.startHeartbeatMonitor()
                        self?.startStatsTimer()
                    }
                    
                    self?.receive(on: connection, connectionId: connectionId)
                    
                    // v64: Debug Connection Path (Router vs P2P)
                    if let path = connection.currentPath {
                        let interfaces = path.availableInterfaces.map { $0.debugDescription }.joined(separator: ", ")
                        LogManager.shared.log("Sender: Connected via Path: \(path)")
                        LogManager.shared.log("Sender: Interfaces: \(interfaces)")
                        
                        // Check for AWDL (usually shows as awdl0 in description or has specific flags)
                        if interfaces.contains("awdl") {
                            LogManager.shared.log("Sender: P2P Direct Link (AWDL) Active ✅")
                        } else {
                            LogManager.shared.log("Sender: Likely using Router/Infrastructure ⚠️")
                        }
                    }
                case .failed(let error):
                    LogManager.shared.log("Sender: Connection to \(service.name) failed: \(error)")
                    self?.removeConnection(connectionId)
                    
                    let remaining = self?.connections.count ?? 0
                    if remaining == 0 {
                        self?.status = "All connections failed"
                        self?.stopStreaming()
                    } else {
                        self?.status = "Connected to \(remaining) device(s)"
                    }
                case .waiting(let error):
                    self?.status = "Waiting... \(error.localizedDescription)"
                default:
                    break
                }
            }
        }
        
        connection.start(queue: .main)
    }
    
    // MARK: - App Controls
    func checkScreenRecordingPermission() {
        // Trigger generic check.
        // For macOS 11+, requesting CGWindowList or SCShareableContent triggers the prompt if mostly bundled correctly.
        // We use SCShareableContent.current asynchronously to trigger it without blocking main thread hard.
        Task {
            do {
                _ = try await SCShareableContent.current
                LogManager.shared.log("Permission Check: Screen Recording access appears active ✅")
            } catch {
                LogManager.shared.log("Permission Check: Screen Recording access might be missing or pending. Watch for System Popup. ⚠️")
            }
        }
    }

    func openPrivacySettings() {
        // macOS 13+ Deep Link
        if let url = URL(string: "x-apple.systempreferences:com.apple.PrivacySecurity.extension?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        // Fallback for older macOS
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
    
    func resetScreenCapturePermissions() {
        LogManager.shared.log("Permissions: Attempting to reset TCC database for ScreenCapture...")
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "ScreenCapture", "com.bettercast.sender"]
        
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                 LogManager.shared.log("Permissions: Reset Successful! Restarting app will trigger the System Popup again.")
                 // Auto-restart?
                 DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                     self.restartApp()
                 }
            } else {
                 LogManager.shared.log("Permissions: Reset Failed (Code \(process.terminationStatus)). You may need to remove it manually in Settings.")
                 openPrivacySettings()
            }
        } catch {
             LogManager.shared.log("Permissions: Error executing tccutil - \(error)")
        }
    }
    
    func quitApp() {
        NSApplication.shared.terminate(nil)
    }
    
    func restartApp() {
        let url = URL(fileURLWithPath: Bundle.main.bundlePath)
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        
        NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
            if error == nil {
                DispatchQueue.main.async {
                    NSApplication.shared.terminate(nil)
                }
            } else {
                LogManager.shared.log("Sender: Failed to restart - \(error?.localizedDescription ?? "")")
            }
        }
    }
    
    // MARK: - Dynamic Updates
    func updateStreamResolution() {
        // Seamlessly update resolution while keeping connection alive.
        LogManager.shared.log("Sender: Updating Resolution dynamically...")
        
        // 1. Stop components
        screenRecorder?.stopCapture()
        screenRecorder = nil
        videoEncoder = nil
        virtualDisplayManager?.destroyDisplay()
        virtualDisplayManager = nil
        
        // 2. Restart components (startStreaming logic)
        // We use a slight delay to allow destruction to complete
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
             self?.startStreaming()
        }
    }
    
    func startHeartbeatMonitor() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if !self.connections.isEmpty {
                let now = Date()
                var disconnectedIds: [UUID] = []
                
                for (id, info) in self.connections {
                    let interval = now.timeIntervalSince(info.lastHeartbeat)
                    if interval > 15.0 {
                        LogManager.shared.log("Sender: Connection to \(info.service.name) timed out (No Heartbeat for 15s)")
                        disconnectedIds.append(id)
                    }
                }
                
                for id in disconnectedIds {
                    self.removeConnection(id)
                }
            }
        }
    }
    
    func removeConnection(_ connectionId: UUID) {
        guard let info = connections[connectionId] else { return }
        
        info.connection.cancel()
        connections.removeValue(forKey: connectionId)
        connectedServices.removeAll { $0.name == info.service.name }
        
        let remaining = connections.count
        LogManager.shared.log("Sender: Disconnected from \(info.service.name). Remaining: \(remaining)")
        
        if remaining == 0 {
            stopStreaming()
            status = "Disconnected"
            heartbeatTimer?.invalidate()
        } else {
            status = "Connected to \(remaining) device(s)"
        }
    }
    
    func disconnect() {
        for (_, info) in connections {
            info.connection.cancel()
        }
        connections.removeAll()
        connectedServices.removeAll()
        stopStreaming()
        status = "Disconnected"
        heartbeatTimer?.invalidate()
    }
    
    func disconnectService(_ service: DiscoveredService) {
        if let entry = connections.first(where: { $0.value.service.name == service.name }) {
            removeConnection(entry.key)
        }
    }
    
    private func startStatsTimer() {
        // Simple timer to update transfer rate UI
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            if self.connections.isEmpty { timer.invalidate(); return }
            
            let bytes = self.bytesSentWindow
            self.bytesSentWindow = 0
            
            let mbps = Double(bytes * 8) / 1_000_000.0
            self.transferRate = String(format: "%.1f Mbps", mbps)
        }
    }
    
    private func receive(on connection: NWConnection, connectionId: UUID) {
         if connectionType == "UDP" {
             receiveUDP(on: connection, connectionId: connectionId)
         } else {
             receiveTCP(on: connection, connectionId: connectionId)
         }
    }
    
    private func receiveTCP(on connection: NWConnection, connectionId: UUID) {
        // Read 4-byte length
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] content, contentContext, isComplete, error in
            if let error = error {
                LogManager.shared.log("Sender: Receive error \(error)")
                return
            }
            
            // Update heartbeat for this specific connection
            if var info = self?.connections[connectionId] {
                info.lastHeartbeat = Date()
                self?.connections[connectionId] = info
            }
            
            if let content = content, content.count == 4 {
                let length = content.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
                let bodyLength = Int(length)
                
                connection.receive(minimumIncompleteLength: bodyLength, maximumLength: bodyLength) { body, bodyContext, isComplete, error in
                    if let body = body {
                        // Decode InputEvent
                        if let event = try? JSONDecoder().decode(InputEvent.self, from: body) {
                            if event.type == .command && event.keyCode == 888 {
                                // Heartbeat message - ignore
                            } else if event.type == .command && event.keyCode == 999 {
                                self?.videoEncoder?.forceKeyframe()
                            } else if self?.isDuplicateEvent(event.eventId) == false {
                                InputHandler.shared.handle(event: event)
                            }
                        }
                    }
                    self?.receiveTCP(on: connection, connectionId: connectionId)
                }
            } else {
                 self?.receiveTCP(on: connection, connectionId: connectionId)
            }
        }
    }
    
    private func receiveUDP(on connection: NWConnection, connectionId: UUID) {
        connection.receiveMessage { [weak self] content, contentContext, isComplete, error in
             if let error = error {
                 LogManager.shared.log("Sender: Receive UDP error \(error)")
                 
                 // Check for straight up rejection (Firewall or Port Closed)
                 if case let NWError.posix(code) = error, code == .ECONNREFUSED {
                     DispatchQueue.main.async { [weak self] in
                         self?.connectionRefusedCount += 1
                         if (self?.connectionRefusedCount ?? 0) > 5 {
                             LogManager.shared.log("Sender: CRITICAL - Receiver is refusing connection (Firewall?). Stopping.")
                             self?.removeConnection(connectionId)
                         }
                     }
                 }
                 return
             }
             
             // Update heartbeat for this specific connection
             if var info = self?.connections[connectionId] {
                 info.lastHeartbeat = Date()
                 self?.connections[connectionId] = info
             }
             
             if let content = content {
                 if content.count > 4 {
                     let body = content.subdata(in: 4..<content.count)
                     if let event = try? JSONDecoder().decode(InputEvent.self, from: body) {
                         if event.type == .command && event.keyCode == 888 {
                             // Heartbeat message - ignore
                         } else if event.type == .command && event.keyCode == 999 {
                             self?.videoEncoder?.forceKeyframe()
                         } else if self?.isDuplicateEvent(event.eventId) == false {
                             InputHandler.shared.handle(event: event)
                         }
                     }
                 }
             }
             self?.receiveUDP(on: connection, connectionId: connectionId)
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
        
    // VideoEncoderDelegate - BROADCAST to all connections
    func videoEncoder(_ encoder: VideoEncoder, didEncode data: Data) {
        guard !connections.isEmpty else { return }
        
        if connectionType == "UDP" {
            // UDP: Fragmentation Logic - Send to ALL connections
            let mtu = 1000 
            let headerSize = 8
            let maxPayload = mtu - headerSize
            
            udpFrameId &+= 1
            let thisFrameId = udpFrameId
            
            let totalData = data
            let totalCount = totalData.count
            
            // Track bandwidth
            bytesSentWindow += totalCount * connections.count // Multiply by receiver count
            
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
                
                let isLargeFrame = totalChunks > 10
                let pacingMicroseconds: useconds_t = 120
                
                // Broadcast to ALL connections
                for (connectionId, info) in connections {
                    info.connection.send(content: finalPacket, completion: .contentProcessed { [weak self] error in
                        if let error = error {
                            // Check for specific error codes
                            if case let NWError.posix(code) = error {
                                switch code {
                                case .ECANCELED:
                                    // iOS disconnected or connection was canceled
                                    LogManager.shared.log("Sender: Connection to \(info.service.name) canceled (Device disconnected)")
                                    DispatchQueue.main.async {
                                        self?.removeConnection(connectionId)
                                    }
                                    return
                                case .ECONNREFUSED:
                                    LogManager.shared.log("Sender: Connection refused by \(info.service.name)")
                                    return
                                default:
                                    break
                                }
                            }
                            LogManager.shared.log("Sender: UDP Chunk Error to \(info.service.name): \(error)")
                        }
                    })
                }
                
                if isLargeFrame && chunkIndex < totalChunks - 1 {
                    usleep(pacingMicroseconds)
                }
            }
        } else {
            // TCP: Length-prefixed framing - Send to ALL connections
            var lengthPrefix = UInt32(data.count).bigEndian
            var packet = Data(bytes: &lengthPrefix, count: 4)
            packet.append(data)
            
            bytesSentWindow += packet.count * connections.count
            
            // Broadcast to ALL connections
            for (_, info) in connections {
                info.connection.send(content: packet, completion: .contentProcessed { error in
                    if let error = error {
                        LogManager.shared.log("Sender: TCP Send Error to \(info.service.name): \(error)")
                    }
                })
            }
        }
    }
}
