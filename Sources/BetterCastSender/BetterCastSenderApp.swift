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
                VStack(spacing: 20) {
                    // Status bar
                    HStack {
                        Spacer()
                        StatusBadge(status: networkClient.status, isConnected: networkClient.isConnected)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 8)

                    // Devices Card
                    DashboardCard {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionHeader(
                                title: "Devices",
                                icon: "display.2",
                                info: "Receivers on your network appear here automatically. Use Manual Connect for Windows/Linux receivers if they don't show up. Android devices connect via ADB."
                            )

                            if networkClient.foundServices.isEmpty && networkClient.connectedServices.isEmpty {
                                HStack {
                                    Spacer()
                                    VStack(spacing: 8) {
                                        ProgressView()
                                            .scaleEffect(0.8)
                                        Text("Searching for receivers...")
                                            .font(.subheadline)
                                            .foregroundStyle(.tertiary)
                                    }
                                    .padding(.vertical, 24)
                                    Spacer()
                                }
                            } else {
                                ForEach(networkClient.foundServices, id: \.name) { service in
                                    ServiceRow(service: service, client: networkClient)
                                    if service.name != networkClient.foundServices.last?.name {
                                        Divider()
                                    }
                                }
                            }

                            Divider()

                            // Manual connection
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Manual Connect")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)
                                HStack(spacing: 8) {
                                    TextField("IP / hostname", text: $networkClient.manualHost)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(size: 13))
                                    TextField("Port", text: $networkClient.manualPort)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(size: 13))
                                        .frame(width: 70)
                                    Button("Connect") {
                                        networkClient.connectManual()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .tint(.accentColor)
                                    .disabled(networkClient.manualHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                }
                            }

                            Divider()

                            // ADB Wireless (Android)
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Android (ADB)")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)
                                HStack(spacing: 8) {
                                    Button(networkClient.adbInProgress ? "Setting up..." : "ADB Wireless") {
                                        networkClient.connectADBWireless()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .tint(.green)
                                    .disabled(networkClient.adbInProgress)

                                    Button("ADB USB") {
                                        networkClient.connectADBUSB()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .tint(.blue)

                                    if !networkClient.adbStatus.isEmpty {
                                        Text(networkClient.adbStatus)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 24)

                    // Connected Displays Card (shown when devices are connected)
                    if !networkClient.connectedDisplays.isEmpty {
                        DashboardCard {
                            VStack(alignment: .leading, spacing: 12) {
                                SectionHeader(
                                    title: "Connected Displays",
                                    icon: "rectangle.on.rectangle",
                                    info: "Each connected device gets its own virtual display. Arrange displays in System Settings > Displays. Toggle the speaker icon to enable/disable audio output per device."
                                )

                                ForEach(networkClient.connectedDisplays) { display in
                                    ConnectedDisplayRow(display: display, client: networkClient)
                                    if display.id != networkClient.connectedDisplays.last?.id {
                                        Divider()
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 24)
                    }

                    // Display & Connection Settings — side by side cards
                    HStack(alignment: .top, spacing: 16) {
                        // Display Settings Card
                        DashboardCard {
                            VStack(alignment: .leading, spacing: 14) {
                                SectionHeader(
                                    title: "Display",
                                    icon: "display",
                                    info: "Virtual Display creates an extra monitor for each receiver. Resolution applies to new connections. Retina doubles the pixel density (sharper but more bandwidth). Audio Streaming sends system sound to receivers."
                                )

                                SettingsRow(label: "Virtual Display") {
                                    Toggle("", isOn: $networkClient.useVirtualDisplay)
                                        .labelsHidden()
                                        .toggleStyle(.switch)
                                }

                                SettingsRow(label: "Resolution") {
                                    Picker("", selection: $networkClient.selectedResolution) {
                                        ForEach(VirtualDisplayManager.defaultResolutions, id: \.self) { res in
                                            Text(res.name).tag(res)
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(width: 140)
                                    .disabled(!networkClient.useVirtualDisplay)
                                }

                                SettingsRow(label: "Retina (HiDPI)") {
                                    Toggle("", isOn: $networkClient.isRetina)
                                        .labelsHidden()
                                        .toggleStyle(.switch)
                                        .disabled(!networkClient.useVirtualDisplay)
                                }

                                SettingsRow(label: "Audio Streaming") {
                                    Toggle("", isOn: $networkClient.audioStreamingEnabled)
                                        .labelsHidden()
                                        .toggleStyle(.switch)
                                }
                            }
                        }

                        // Connection Settings Card
                        DashboardCard {
                            VStack(alignment: .leading, spacing: 14) {
                                SectionHeader(
                                    title: "Connection",
                                    icon: "network",
                                    info: "Auto works with all platforms (Windows, Linux, Android, Apple). Force P2P uses WiFi Direct for lowest latency but only works between Apple devices. Force Router/WiFi uses your local network. TCP is recommended for reliability."
                                )

                                SettingsRow(label: "Mode") {
                                    Picker("", selection: $networkClient.interfacePreference) {
                                        ForEach(NetworkInterfacePreference.allCases) { pref in
                                            Text(pref.rawValue).tag(pref)
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(width: 160)
                                    .disabled(networkClient.isConnected)
                                }

                                SettingsRow(label: "Protocol") {
                                    Picker("", selection: $networkClient.connectionType) {
                                        Text("TCP (Recommended)").tag("TCP")
                                        Text("UDP (Faster, P2P only)").tag("UDP")
                                    }
                                    .labelsHidden()
                                    .frame(width: 140)
                                }

                                SettingsRow(label: "Quality") {
                                    Picker("", selection: $networkClient.selectedQuality) {
                                        ForEach(StreamQuality.allCases) { quality in
                                            Text(quality.name).tag(quality)
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(width: 140)
                                }

                                if networkClient.isConnected {
                                    SettingsRow(label: "Transfer Speed") {
                                        Text(networkClient.transferRate)
                                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(.green)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 24)

                    // Controls Card
                    DashboardCard {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionHeader(
                                title: "Controls",
                                icon: "gearshape",
                                info: "Apply Settings updates resolution/quality on active connections. Screen Recording permission is required for capturing your display."
                            )

                            HStack(spacing: 10) {
                                CardButton(title: "Apply Settings", color: .accentColor) {
                                    if networkClient.isConnected {
                                        networkClient.updateStreamResolution()
                                    }
                                }
                                .disabled(!networkClient.isConnected)

                                CardButton(title: "Screen Recording Settings", color: .blue) {
                                    networkClient.openPrivacySettings()
                                }

                                CardButton(title: "Reset Permissions", color: .orange) {
                                    networkClient.resetScreenCapturePermissions()
                                }

                                CardButton(title: "Restart App", color: Color(.secondaryLabelColor)) {
                                    networkClient.restartApp()
                                }

                                CardButton(title: "Quit", color: .red) {
                                    networkClient.quitApp()
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 24)

                    // Logs Card
                    LogView()
                        .padding(.horizontal, 24)
                }
                .padding(.bottom, 20)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle("BetterCast")
            .frame(minWidth: 580, minHeight: 720)
            .onAppear {
                networkClient.checkScreenRecordingPermission()
                networkClient.startBrowsing()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                     InputHandler.shared.checkAccessibility()
                }
            }
        }
    }
}

// MARK: - Dashboard Card Container

struct DashboardCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.06), radius: 6, x: 0, y: 2)
            )
    }
}

// Extension for cards that need outer padding (standalone cards)
extension DashboardCard {
    init(padded: Bool = true, @ViewBuilder content: () -> Content) {
        self.content = content()
    }
}

// MARK: - Status Badge

struct StatusBadge: View {
    let status: String
    let isConnected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isConnected ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(status)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            Capsule()
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 1)
        )
    }
}

// MARK: - Service Row

struct ServiceRow: View {
    let service: DiscoveredService
    @ObservedObject var client: NetworkClient

    private var isConnected: Bool {
        client.connectedServices.contains(where: { $0.name == service.name })
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isConnected ? "display" : "display.trianglebadge.exclamationmark")
                .font(.system(size: 16))
                .foregroundStyle(isConnected ? .green : .secondary)
                .frame(width: 24)
            Text(service.name)
                .font(.system(size: 14, weight: .medium))
            Spacer()
            if isConnected {
                Text("Connected")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.green)
                Button("Disconnect") {
                    client.disconnectService(service)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
            } else {
                Button("Connect") {
                    client.connect(to: service)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.accentColor)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Connected Display Info

struct ConnectedDisplayInfo: Identifiable {
    let id: UUID  // connectionId
    let name: String
    let resolution: String
    let displayBounds: CGRect
    var audioEnabled: Bool
}

// MARK: - Connected Display Row

struct ConnectedDisplayRow: View {
    let display: ConnectedDisplayInfo
    @ObservedObject var client: NetworkClient

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "display")
                .font(.system(size: 16))
                .foregroundStyle(.green)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(display.name)
                    .font(.system(size: 13, weight: .medium))
                Text(display.resolution)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if display.displayBounds != .zero {
                    Text("Position: (\(Int(display.displayBounds.origin.x)), \(Int(display.displayBounds.origin.y)))")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { display.audioEnabled },
                set: { client.setAudioEnabled($0, for: display.id) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .help("Audio output to this display")
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 12))
                .foregroundStyle(display.audioEnabled ? .primary : .tertiary)
            Button("Disconnect") {
                client.disconnectConnection(display.id)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.red)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Settings Row

struct SettingsRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
            Spacer()
            content
        }
    }
}

// MARK: - Card Button

struct CardButton: View {
    let title: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(color, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Info Button (click to show popover)

struct InfoButton: View {
    let text: String
    @State private var showPopover = false

    var body: some View {
        Button(action: { showPopover.toggle() }) {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            Text(text)
                .font(.system(size: 12))
                .padding(12)
                .frame(maxWidth: 280)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Section Header with Info

struct SectionHeader: View {
    let title: String
    let icon: String
    let info: String

    var body: some View {
        HStack(spacing: 6) {
            Label(title, systemImage: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
            InfoButton(text: info)
        }
    }
}

// MARK: - Settings View (kept for backwards compatibility but now unused inline)

struct SettingsView: View {
    @ObservedObject var client: NetworkClient
    var body: some View { EmptyView() }
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

// Per-connection pipeline: each device gets its own virtual display, screen capture, and encoder
struct ConnectionPipeline {
    let id: UUID
    let connection: NWConnection
    let service: DiscoveredService
    var lastHeartbeat: Date

    // Per-connection components (isolated pipeline)
    var virtualDisplayManager: VirtualDisplayManager?
    var screenRecorder: ScreenRecorder?
    var videoEncoder: VideoEncoder?
    var audioEncoder: AudioEncoder?

    // Adaptive: P2P (AWDL) connections get full quality; infrastructure gets throttled
    var isP2P: Bool = false
    // Loopback connections (ADB tunnel via lo0) — high bandwidth, skip backpressure
    var isLoopback: Bool = false
    // TCP backpressure: skip frames while a send is still in flight
    var sendInProgress: Bool = false
    // Time-based send pacing for WiFi ADB (prevents kernel buffer bloat)
    var lastSendTimeNs: UInt64 = 0
    // WiFi ADB vs USB ADB — WiFi has much less bandwidth, needs throttling
    var isWiFiADB: Bool = false
    // ADB/localhost connections always use TCP framing regardless of global protocol setting
    var forceTCP: Bool = false
}

class NetworkClient: ObservableObject, VideoEncoderDelegate, AudioEncoderDelegate {
    private var browser: NWBrowser?
    private var pipelines: [UUID: ConnectionPipeline] = [:]

    @Published var status: String = "Idle"
    @Published var foundServices: [DiscoveredService] = []
    @Published var connectedServices: [DiscoveredService] = []
    @Published var useVirtualDisplay: Bool = true // Toggle between mirroring and extended display
    @Published var audioStreamingEnabled: Bool = false // Master toggle for audio streaming
    @Published var connectedDisplays: [ConnectedDisplayInfo] = [] // Per-device display info

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
    @Published var selectedResolution: VirtualDisplayManager.Resolution = VirtualDisplayManager.defaultResolutions[1]
    @Published var isRetina: Bool = false
    @Published var connectionType: String = "TCP" {
        didSet {
            // Restart browsing if type changes
            browser?.cancel()
            startBrowsing()
        }
    }
    
    @Published var selectedQuality: StreamQuality = .high
    
    // v67: Manual Interface Toggle — default Auto so Windows/Linux/Android receivers work out of the box
    @Published var interfacePreference: NetworkInterfacePreference = .auto

    // Manual connection
    @Published var manualHost: String = ""
    @Published var manualPort: String = "51820"

    var isConnected: Bool { !pipelines.isEmpty }


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
            tcpOptions.noDelay = true
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
                guard let self = self else { return }
                // Build list from mDNS browse results
                var services = results.compactMap { result -> DiscoveredService? in
                    if case .service(let name, _, _, _) = result.endpoint {
                        return DiscoveredService(name: name, endpoint: result.endpoint)
                    }
                    return nil
                }
                // Preserve manual connections that aren't from mDNS
                for existing in self.foundServices {
                    if case .hostPort = existing.endpoint,
                       !services.contains(where: { $0.name == existing.name }) {
                        services.append(existing)
                    }
                }
                self.foundServices = services
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
                // Cache Infra WiFi (en0 typically) — only log on first discovery
                if interface.type == .wifi && !interface.name.contains("awdl") && !interface.name.contains("llw") {
                     let isNew = self?.cachedInfraInterface == nil
                     self?.cachedInfraInterface = interface
                     if isNew {
                         LogManager.shared.log("Network: Found Infra Interface: \(interface.name) (\(interface.type))")
                     }
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
            parameters.serviceClass = .interactiveVideo
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

        let deviceCount = pipelines.count + 1
        self.status = "Connecting to \(service.name) (Device #\(deviceCount))..."

        let parameters: NWParameters
        switch connectionType {
        case "UDP":
            parameters = NWParameters.udp
        default: // TCP
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.enableKeepalive = true
            tcpOptions.noDelay = true
            tcpOptions.connectionTimeout = 10
            parameters = NWParameters(tls: nil, tcp: tcpOptions)
            parameters.serviceClass = .interactiveVideo
        }

        configureParameters(parameters)
        LogManager.shared.log("Sender: Connecting with Pref: \(interfacePreference.rawValue)")

        let connection = NWConnection(to: service.endpoint, using: parameters)
        let connectionId = UUID()

        connection.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    // Detect link type before creating pipeline
                    var isP2P = false
                    var isLoopback = false
                    if let path = connection.currentPath {
                        let interfaces = path.availableInterfaces.map { $0.debugDescription }.joined(separator: ", ")
                        LogManager.shared.log("Sender: Connected via Path: \(path)")
                        LogManager.shared.log("Sender: Interfaces: \(interfaces)")

                        if interfaces.contains("awdl") {
                            isP2P = true
                            LogManager.shared.log("Sender: P2P Direct Link (AWDL) Active ✅")
                        } else if interfaces.contains("lo0") || interfaces.contains("loopback") {
                            isLoopback = true
                            LogManager.shared.log("Sender: Loopback/ADB tunnel — high bandwidth mode 🔌")
                        } else {
                            LogManager.shared.log("Sender: Likely using Router/Infrastructure ⚠️")
                        }
                    }

                    // Create pipeline for this connection
                    var pipeline = ConnectionPipeline(
                        id: connectionId,
                        connection: connection,
                        service: service,
                        lastHeartbeat: Date()
                    )
                    pipeline.isP2P = isP2P
                    pipeline.isLoopback = isLoopback
                    self?.pipelines[connectionId] = pipeline
                    self?.connectedServices.append(service)
                    self?.updateConnectedDisplays()

                    let count = self?.pipelines.count ?? 0
                    self?.status = "Connected to \(count) device(s)"
                    LogManager.shared.log("Sender: Connected to \(service.name) (Total: \(count), P2P: \(isP2P))")

                    // Start per-connection pipeline (each device gets its own display/encoder/recorder)
                    self?.startPipeline(for: connectionId)

                    // Start shared services on first connection
                    if count == 1 {
                        self?.startHeartbeatMonitor()
                        self?.startStatsTimer()
                    }

                    self?.receive(on: connection, connectionId: connectionId)
                case .failed(let error):
                    LogManager.shared.log("Sender: Connection to \(service.name) failed: \(error)")
                    self?.removeConnection(connectionId)

                    let remaining = self?.pipelines.count ?? 0
                    if remaining == 0 {
                        self?.status = "All connections failed"
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

    func connectManual() {
        let host = manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }
        guard let portNum = UInt16(manualPort), portNum > 0 else {
            LogManager.shared.log("Sender: Invalid port '\(manualPort)'")
            return
        }

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: portNum)!
        )
        let service = DiscoveredService(name: "\(host):\(portNum)", endpoint: endpoint)

        // Add to foundServices so it appears in the Devices list with status/disconnect
        if !foundServices.contains(where: { $0.name == service.name }) {
            foundServices.append(service)
        }

        // For manual connections, use plain TCP with no interface restrictions
        // This allows localhost/ADB forwarding to work regardless of Mode setting
        let isLocalhost = host == "localhost" || host == "127.0.0.1"

        if isLocalhost {
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.enableKeepalive = true
            tcpOptions.noDelay = true
            let parameters = NWParameters(tls: nil, tcp: tcpOptions)
            parameters.serviceClass = .interactiveVideo
            LogManager.shared.log("Sender: Manual connect to \(host):\(portNum) (localhost/ADB mode, no interface restrictions)")
            connectWithParameters(service: service, parameters: parameters, forceTCP: true)
        } else {
            // Non-localhost manual connect: use plain TCP without interface restrictions
            // This ensures connections to Windows/Linux receivers on the LAN work
            // regardless of the Mode setting (which may force P2P/AWDL)
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.enableKeepalive = true
            tcpOptions.noDelay = true
            let parameters = NWParameters(tls: nil, tcp: tcpOptions)
            parameters.serviceClass = .interactiveVideo
            LogManager.shared.log("Sender: Manual connect to \(host):\(portNum) (LAN mode, no interface restrictions)")
            connectWithParameters(service: service, parameters: parameters, forceTCP: false)
        }
    }

    // MARK: - ADB Wireless

    @Published var adbStatus: String = ""
    @Published var adbInProgress: Bool = false

    /// Run an ADB shell command and return trimmed stdout
    private func runAdb(_ args: [String]) -> (output: String, success: Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/adb")
        process.arguments = args
        let pipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errPipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (output, process.terminationStatus == 0)
        } catch {
            return ("", false)
        }
    }

    /// Get the Android device's WiFi IP address via ADB
    /// - Parameter serial: Optional device serial to target (required when multiple devices connected)
    private func getDeviceIP(serial: String? = nil) -> String? {
        let deviceArgs: [String] = serial.map { ["-s", $0] } ?? []

        // Method 1: ip route — look for wlan0 specifically (not cellular)
        let routeResult = runAdb(deviceArgs + ["shell", "ip", "route"])
        if routeResult.success {
            let lines = routeResult.output.components(separatedBy: "\n")
            for line in lines {
                // Must be wlan0 to avoid picking up cellular IP
                if line.contains("wlan0") && line.contains("src") {
                    let parts = line.components(separatedBy: " ")
                    if let srcIdx = parts.firstIndex(of: "src"), srcIdx + 1 < parts.count {
                        let ip = parts[srcIdx + 1]
                        if isPrivateIP(ip) { return ip }
                    }
                }
            }
        }

        // Method 2: ip addr show wlan0 — parse inet line
        let addrResult = runAdb(deviceArgs + ["shell", "ip", "addr", "show", "wlan0"])
        if addrResult.success {
            let lines = addrResult.output.components(separatedBy: "\n")
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("inet ") {
                    // "inet 192.168.1.100/24 ..."
                    let parts = trimmed.components(separatedBy: " ")
                    if parts.count >= 2 {
                        let ip = parts[1].components(separatedBy: "/").first ?? ""
                        if isPrivateIP(ip) { return ip }
                    }
                }
            }
        }

        return nil
    }

    /// Check if IP is a private/local address (not cellular)
    private func isPrivateIP(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return false }
        // 192.168.x.x, 10.x.x.x, 172.16-31.x.x
        if ip.hasPrefix("192.168.") || ip.hasPrefix("10.") { return true }
        if ip.hasPrefix("172."), let second = Int(parts[1]), (16...31).contains(second) { return true }
        return false
    }

    /// Full ADB wireless handoff: USB → tcpip → forward → connect
    func connectADBWireless() {
        guard !adbInProgress else { return }
        adbInProgress = true
        adbStatus = "Checking device..."

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // 1. Check for connected devices (USB and/or WiFi)
            let devices = self.runAdb(["devices"])
            let allLines = devices.output.components(separatedBy: "\n").filter { $0.contains("\tdevice") }
            let usbLines = allLines.filter { !$0.contains(":") }
            let wifiLines = allLines.filter { $0.contains(":") }

            // If already connected via WiFi ADB, just set up port forwarding directly
            if let wifiLine = wifiLines.first {
                let wifiSerial = wifiLine.components(separatedBy: "\t").first ?? ""
                LogManager.shared.log("ADB Wireless: Already connected via WiFi: \(wifiSerial)")

                // Disconnect existing streaming pipeline
                DispatchQueue.main.async {
                    self.adbStatus = "Setting up wireless tunnel..."
                    let adbNames = ["Android (USB)", "Android (WiFi ADB)", "localhost:51820"]
                    for name in adbNames {
                        if let entry = self.pipelines.first(where: { $0.value.service.name == name }) {
                            self.removeConnection(entry.key)
                            LogManager.shared.log("ADB Wireless: Disconnected existing '\(name)'")
                        }
                    }
                }
                Thread.sleep(forTimeInterval: 0.3)

                // Set up port forwarding through existing WiFi connection
                let forwardResult = self.runAdb(["-s", wifiSerial, "forward", "tcp:51820", "tcp:51820"])
                LogManager.shared.log("ADB Wireless: forward result: \(forwardResult.output)")

                DispatchQueue.main.async {
                    self.adbStatus = "Connecting stream..."
                    LogManager.shared.log("ADB Wireless: Tunnel ready via existing WiFi — connecting to localhost:51820")
                    self.connectADBTunnel(displayName: "Android (WiFi ADB)")

                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self.adbStatus = "Wireless ADB active"
                        self.adbInProgress = false
                    }
                }
                return
            }

            // No WiFi ADB — need USB device to do the handoff
            guard !usbLines.isEmpty else {
                DispatchQueue.main.async {
                    self.adbStatus = "No USB or WiFi device found"
                    self.adbInProgress = false
                    LogManager.shared.log("ADB Wireless: No USB or WiFi ADB device connected")
                }
                return
            }

            let serial = usbLines[0].components(separatedBy: "\t").first ?? ""
            DispatchQueue.main.async {
                self.adbStatus = "Found: \(serial)"
                LogManager.shared.log("ADB Wireless: Found USB device \(serial)")
            }

            // 2. Get device IP over USB (pass serial to avoid "more than one device" error)
            guard let deviceIP = self.getDeviceIP(serial: serial) else {
                DispatchQueue.main.async {
                    self.adbStatus = "Cannot get device IP"
                    self.adbInProgress = false
                    LogManager.shared.log("ADB Wireless: Failed to get device IP via 'ip route'")
                }
                return
            }

            DispatchQueue.main.async {
                self.adbStatus = "Device IP: \(deviceIP)"
                LogManager.shared.log("ADB Wireless: Device IP is \(deviceIP)")
            }

            // 3. Disconnect existing ADB connection first (tcpip will kill USB tunnel anyway)
            DispatchQueue.main.async {
                self.adbStatus = "Switching to wireless — disconnecting USB..."
                let adbNames = ["Android (USB)", "Android (WiFi ADB)", "localhost:51820"]
                for name in adbNames {
                    if let entry = self.pipelines.first(where: { $0.value.service.name == name }) {
                        self.removeConnection(entry.key)
                        LogManager.shared.log("ADB Wireless: Disconnected existing '\(name)' before switching")
                    }
                }
            }
            Thread.sleep(forTimeInterval: 0.5)

            // 4. Enable TCP/IP mode on device
            DispatchQueue.main.async {
                self.adbStatus = "Switching to wireless — enabling TCP mode..."
                LogManager.shared.log("ADB Wireless: Running 'adb tcpip 5555'...")
            }
            let tcpipResult = self.runAdb(["-s", serial, "tcpip", "5555"])
            LogManager.shared.log("ADB Wireless: tcpip result: \(tcpipResult.output)")

            // Wait for ADB daemon to restart
            Thread.sleep(forTimeInterval: 3.0)

            // 5. Connect to device over WiFi
            DispatchQueue.main.async {
                self.adbStatus = "Switching to wireless — connecting \(deviceIP)..."
                LogManager.shared.log("ADB Wireless: Connecting to \(deviceIP):5555...")
            }

            var connected = false
            for attempt in 1...10 {
                let connectResult = self.runAdb(["connect", "\(deviceIP):5555"])
                LogManager.shared.log("ADB Wireless: connect attempt \(attempt): \(connectResult.output)")
                if connectResult.output.contains("connected") {
                    connected = true
                    break
                }
                Thread.sleep(forTimeInterval: 1.5)
            }

            guard connected else {
                DispatchQueue.main.async {
                    self.adbStatus = "WiFi connect failed — check WiFi"
                    self.adbInProgress = false
                    LogManager.shared.log("ADB Wireless: Failed to connect over WiFi after 10 attempts")
                }
                return
            }

            // 6. Set up port forwarding (through the WiFi ADB connection)
            DispatchQueue.main.async {
                self.adbStatus = "Switching to wireless — setting up tunnel..."
                LogManager.shared.log("ADB Wireless: Setting up port forward on \(deviceIP):5555...")
            }
            let forwardResult = self.runAdb(["-s", "\(deviceIP):5555", "forward", "tcp:51820", "tcp:51820"])
            LogManager.shared.log("ADB Wireless: forward result: \(forwardResult.output)")

            // 7. Connect sender to localhost:51820 (tunneled through WiFi ADB)
            DispatchQueue.main.async {
                self.adbStatus = "Connecting stream..."
                LogManager.shared.log("ADB Wireless: Tunnel ready — connecting to localhost:51820")
                self.connectADBTunnel(displayName: "Android (WiFi ADB)")

                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.adbStatus = "Wireless ADB active"
                    self.adbInProgress = false
                    LogManager.shared.log("ADB Wireless: Setup complete — streaming via WiFi ADB tunnel")
                }
            }
        }
    }

    /// Quick ADB USB-only: just forward port and connect (no wireless handoff)
    func connectADBUSB() {
        adbStatus = "Forwarding port..."
        LogManager.shared.log("ADB USB: Setting up port forward...")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // Find USB device serial (filter out wireless connections which contain ":")
            let devices = self.runAdb(["devices"])
            let usbLines = devices.output.components(separatedBy: "\n").filter {
                $0.contains("\tdevice") && !$0.contains(":")
            }
            let serial = usbLines.first?.components(separatedBy: "\t").first

            // Use -s serial if available (handles multiple-device case)
            let deviceArgs: [String] = serial.map { ["-s", $0] } ?? []
            let forwardResult = self.runAdb(deviceArgs + ["forward", "tcp:51820", "tcp:51820"])
            LogManager.shared.log("ADB USB: forward result: \(forwardResult.output)")

            DispatchQueue.main.async {
                self.adbStatus = "Connecting..."
                self.connectADBTunnel(displayName: "Android (USB)")

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.adbStatus = "USB ADB active"
                    LogManager.shared.log("ADB USB: Connected via USB tunnel")
                }
            }
        }
    }

    /// Connect to ADB-forwarded port with a proper device name that shows in the device list
    private func connectADBTunnel(displayName: String) {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("localhost"),
            port: NWEndpoint.Port(rawValue: 51820)!
        )
        let service = DiscoveredService(name: displayName, endpoint: endpoint)

        // Add to foundServices so it shows in the device list
        if !foundServices.contains(where: { $0.name == displayName }) {
            foundServices.append(service)
        }

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.serviceClass = .interactiveVideo

        LogManager.shared.log("Sender: ADB connect '\(displayName)' via localhost:51820")
        connectWithParameters(service: service, parameters: parameters, forceTCP: true)
    }

    private func connectWithParameters(service: DiscoveredService, parameters: NWParameters, forceTCP: Bool = false) {
        if connectedServices.contains(where: { $0.name == service.name }) {
            LogManager.shared.log("Sender: Already connected to \(service.name)")
            return
        }

        let deviceCount = pipelines.count + 1
        self.status = "Connecting to \(service.name) (Device #\(deviceCount))..."

        let connection = NWConnection(to: service.endpoint, using: parameters)
        let connectionId = UUID()

        connection.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    // Detect link type
                    var isP2P = false
                    var isLoopback = false
                    if let path = connection.currentPath {
                        let interfaces = path.availableInterfaces.map { $0.debugDescription }.joined(separator: ", ")
                        LogManager.shared.log("Sender: Connected via Path: \(path)")
                        LogManager.shared.log("Sender: Interfaces: \(interfaces)")

                        if interfaces.contains("awdl") {
                            isP2P = true
                            LogManager.shared.log("Sender: P2P Direct Link (AWDL) Active ✅")
                        } else if interfaces.contains("lo0") || interfaces.contains("loopback") {
                            isLoopback = true
                            LogManager.shared.log("Sender: Loopback/ADB tunnel — high bandwidth mode 🔌")
                        } else {
                            LogManager.shared.log("Sender: Likely using Router/Infrastructure ⚠️")
                        }
                    }

                    var pipeline = ConnectionPipeline(
                        id: connectionId,
                        connection: connection,
                        service: service,
                        lastHeartbeat: Date()
                    )
                    pipeline.isP2P = isP2P
                    pipeline.isLoopback = isLoopback
                    pipeline.forceTCP = forceTCP
                    pipeline.isWiFiADB = isLoopback && service.name.contains("WiFi")
                    self?.pipelines[connectionId] = pipeline
                    self?.connectedServices.append(service)
                    self?.updateConnectedDisplays()

                    let count = self?.pipelines.count ?? 0
                    self?.status = "Connected to \(count) device(s)"
                    LogManager.shared.log("Sender: Connected to \(service.name) (Total: \(count), P2P: \(isP2P))")

                    self?.startPipeline(for: connectionId)

                    if count == 1 {
                        self?.startHeartbeatMonitor()
                        self?.startStatsTimer()
                    }

                    self?.receive(on: connection, connectionId: connectionId)
                case .failed(let error):
                    LogManager.shared.log("Sender: Connection to \(service.name) failed: \(error)")
                    self?.removeConnection(connectionId)

                    let remaining = self?.pipelines.count ?? 0
                    if remaining == 0 {
                        self?.status = "All connections failed"
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
        LogManager.shared.log("Permissions: Resetting ScreenCapture and Accessibility permissions...")

        var allSuccess = true

        // Reset Screen Recording
        let screenCapture = Process()
        screenCapture.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        screenCapture.arguments = ["reset", "ScreenCapture", "com.bettercast.sender"]
        do {
            try screenCapture.run()
            screenCapture.waitUntilExit()
            if screenCapture.terminationStatus == 0 {
                LogManager.shared.log("Permissions: Screen Recording reset OK")
            } else {
                LogManager.shared.log("Permissions: Screen Recording reset failed (Code \(screenCapture.terminationStatus))")
                allSuccess = false
            }
        } catch {
            LogManager.shared.log("Permissions: Error resetting Screen Recording - \(error)")
            allSuccess = false
        }

        // Reset Accessibility (for mouse/keyboard control)
        let accessibility = Process()
        accessibility.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        accessibility.arguments = ["reset", "Accessibility", "com.bettercast.sender"]
        do {
            try accessibility.run()
            accessibility.waitUntilExit()
            if accessibility.terminationStatus == 0 {
                LogManager.shared.log("Permissions: Accessibility reset OK")
            } else {
                LogManager.shared.log("Permissions: Accessibility reset failed (Code \(accessibility.terminationStatus))")
                allSuccess = false
            }
        } catch {
            LogManager.shared.log("Permissions: Error resetting Accessibility - \(error)")
            allSuccess = false
        }

        if allSuccess {
            LogManager.shared.log("Permissions: All reset! Restarting to re-prompt...")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.restartApp()
            }
        } else {
            LogManager.shared.log("Permissions: Some resets failed. Check Settings manually.")
            openPrivacySettings()
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
        // Seamlessly update resolution while keeping connections alive.
        LogManager.shared.log("Sender: Updating Resolution dynamically for all pipelines...")

        // 1. Stop all pipeline components
        for (id, pipeline) in pipelines {
            pipeline.screenRecorder?.stopCapture()
            pipeline.virtualDisplayManager?.destroyDisplay()
            InputHandler.shared.removeDisplayBounds(for: id)
            pipelines[id]?.screenRecorder = nil
            pipelines[id]?.videoEncoder = nil
            pipelines[id]?.virtualDisplayManager = nil
        }

        // 2. Restart all pipelines with new settings
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            for id in self.pipelines.keys {
                self.startPipeline(for: id)
            }
        }
    }
    
    func startHeartbeatMonitor() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if !self.pipelines.isEmpty {
                let now = Date()
                var disconnectedIds: [UUID] = []

                for (id, pipeline) in self.pipelines {
                    let interval = now.timeIntervalSince(pipeline.lastHeartbeat)
                    if interval > 15.0 {
                        LogManager.shared.log("Sender: Connection to \(pipeline.service.name) timed out (No Heartbeat for 15s)")
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
        guard let pipeline = pipelines[connectionId] else { return }

        // Tear down this connection's pipeline
        pipeline.screenRecorder?.stopCapture()
        pipeline.virtualDisplayManager?.destroyDisplay()
        pipeline.connection.cancel()
        InputHandler.shared.removeDisplayBounds(for: connectionId)

        pipelines.removeValue(forKey: connectionId)
        connectedServices.removeAll { $0.name == pipeline.service.name }

        let remaining = pipelines.count
        LogManager.shared.log("Sender: Disconnected from \(pipeline.service.name). Remaining: \(remaining)")

        if remaining == 0 {
            status = "Disconnected"
            heartbeatTimer?.invalidate()
        } else {
            status = "Connected to \(remaining) device(s)"
        }
        updateConnectedDisplays()
    }

    func disconnect() {
        for (id, pipeline) in pipelines {
            pipeline.screenRecorder?.stopCapture()
            pipeline.virtualDisplayManager?.destroyDisplay()
            pipeline.connection.cancel()
            InputHandler.shared.removeDisplayBounds(for: id)
        }
        pipelines.removeAll()
        connectedServices.removeAll()
        connectedDisplays.removeAll()
        status = "Disconnected"
        heartbeatTimer?.invalidate()
    }

    func disconnectService(_ service: DiscoveredService) {
        if let entry = pipelines.first(where: { $0.value.service.name == service.name }) {
            removeConnection(entry.key)
        }
    }

    func disconnectConnection(_ connectionId: UUID) {
        removeConnection(connectionId)
    }

    func setAudioEnabled(_ enabled: Bool, for connectionId: UUID) {
        if let idx = connectedDisplays.firstIndex(where: { $0.id == connectionId }) {
            connectedDisplays[idx].audioEnabled = enabled
            let name = connectedDisplays[idx].name
            LogManager.shared.log("Sender: Audio \(enabled ? "enabled" : "disabled") for \(name)")
        }
    }

    func updateConnectedDisplays() {
        connectedDisplays = pipelines.map { (id, pipeline) in
            let bounds = InputHandler.shared.getDisplayBounds(for: id)
            let res = bounds.width > 0 ? "\(Int(bounds.width))x\(Int(bounds.height))" : "Initializing..."
            return ConnectedDisplayInfo(
                id: id,
                name: pipeline.service.name,
                resolution: res,
                displayBounds: bounds,
                audioEnabled: connectedDisplays.first(where: { $0.id == id })?.audioEnabled ?? audioStreamingEnabled
            )
        }
    }
    
    private func startStatsTimer() {
        // Simple timer to update transfer rate UI
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            if self.pipelines.isEmpty { timer.invalidate(); return }
            
            let bytes = self.bytesSentWindow
            self.bytesSentWindow = 0
            
            let mbps = Double(bytes * 8) / 1_000_000.0
            self.transferRate = String(format: "%.1f Mbps", mbps)
        }
    }
    
    private func receive(on connection: NWConnection, connectionId: UUID) {
        let useTCP = (pipelines[connectionId]?.forceTCP == true) || connectionType != "UDP"
        if useTCP {
             receiveTCP(on: connection, connectionId: connectionId)
         } else {
             receiveUDP(on: connection, connectionId: connectionId)
         }
    }
    
    private func receiveTCP(on connection: NWConnection, connectionId: UUID) {
        // Don't schedule receives on dead connections
        guard pipelines[connectionId] != nil else { return }

        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] content, contentContext, isComplete, error in
            if let error = error {
                // Fatal errors: connection is truly dead
                if case let NWError.posix(code) = error,
                   (code == .ECONNRESET || code == .ENOTCONN || code == .ECANCELED) {
                    LogManager.shared.log("Sender: Receive error (fatal): \(error)")
                    return
                }
                // Non-fatal (e.g. ENODATA/96): keep receiving, don't spam logs
                self?.receiveTCP(on: connection, connectionId: connectionId)
                return
            }

            if let content = content, content.count == 4 {
                let length = content.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
                let bodyLength = Int(length)

                connection.receive(minimumIncompleteLength: bodyLength, maximumLength: bodyLength) { body, bodyContext, isComplete, error in
                    // All pipelines access must happen on main thread to avoid dictionary races
                    DispatchQueue.main.async {
                        // Update heartbeat
                        self?.pipelines[connectionId]?.lastHeartbeat = Date()

                        if let body = body {
                            if let event = try? JSONDecoder().decode(InputEvent.self, from: body) {
                                if event.type == .command && event.keyCode == 888 {
                                    // Heartbeat - ignore
                                } else if event.type == .command && event.keyCode == 999 {
                                    self?.pipelines[connectionId]?.videoEncoder?.forceKeyframe()
                                } else if self?.isDuplicateEvent(event.eventId) == false {
                                    InputHandler.shared.handle(event: event, for: connectionId)
                                }
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

            // All pipelines access must happen on main thread to avoid dictionary races
            DispatchQueue.main.async {
                self?.pipelines[connectionId]?.lastHeartbeat = Date()

                if let content = content {
                    if content.count > 4 {
                        let body = content.subdata(in: 4..<content.count)
                        if let event = try? JSONDecoder().decode(InputEvent.self, from: body) {
                            if event.type == .command && event.keyCode == 888 {
                                // Heartbeat - ignore
                            } else if event.type == .command && event.keyCode == 999 {
                                self?.pipelines[connectionId]?.videoEncoder?.forceKeyframe()
                            } else if self?.isDuplicateEvent(event.eventId) == false {
                                InputHandler.shared.handle(event: event, for: connectionId)
                            }
                        }
                    }
                }
            }
            self?.receiveUDP(on: connection, connectionId: connectionId)
        }
    }
    
    func startPipeline(for connectionId: UUID) {
        guard pipelines[connectionId] != nil else { return }

        let serviceName = pipelines[connectionId]?.service.name ?? "unknown"
        LogManager.shared.log("Sender: Starting pipeline for \(serviceName)...")

        var targetDisplayID: CGDirectDisplayID? = nil

        // Create virtual display if enabled
        if useVirtualDisplay {
            LogManager.shared.log("Sender: Creating virtual display for \(serviceName)...")
            let displayManager = VirtualDisplayManager()

            let res = selectedResolution
            let resolution = VirtualDisplayManager.Resolution(
                width: res.width,
                height: res.height,
                ppi: isRetina ? min(220, res.ppi * 2) : res.ppi,
                hiDPI: isRetina,
                name: "BetterCast Display (\(serviceName))"
            )

            if let displayID = displayManager.createDisplay(resolution: resolution) {
                targetDisplayID = displayID
                pipelines[connectionId]?.virtualDisplayManager = displayManager

                // Update InputHandler with this connection's display bounds
                // Retry with increasing delays — macOS may take time to register the virtual display
                func pollDisplayBounds(attempt: Int) {
                    let bounds = CGDisplayBounds(displayID)
                    if bounds.width > 0 && bounds.height > 0 {
                        InputHandler.shared.updateDisplayBounds(bounds: bounds, for: connectionId)
                        LogManager.shared.log("Sender: Virtual display for \(serviceName) bounds: \(bounds) (attempt \(attempt))")
                        self.updateConnectedDisplays()
                    } else if attempt < 10 {
                        // Retry after increasing delay (0.5s, 1s, 1.5s, ...)
                        DispatchQueue.main.asyncAfter(deadline: .now() + Double(attempt) * 0.5) {
                            pollDisplayBounds(attempt: attempt + 1)
                        }
                    } else {
                        // Fallback: use the resolution we requested
                        let fallbackBounds = CGRect(x: 0, y: 0, width: res.width, height: res.height)
                        InputHandler.shared.updateDisplayBounds(bounds: fallbackBounds, for: connectionId)
                        LogManager.shared.log("Sender: Virtual display bounds unavailable after retries, using fallback: \(fallbackBounds)")
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    pollDisplayBounds(attempt: 1)
                }

                LogManager.shared.log("Sender: Virtual display created for \(serviceName) with ID \(displayID)")
                LogManager.shared.log("Sender: Go to System Settings > Displays to arrange it")
            } else {
                LogManager.shared.log("Sender: Failed to create virtual display for \(serviceName), using main screen")
            }
        } else {
            LogManager.shared.log("Sender: Using main screen (mirroring mode) for \(serviceName)")
        }

        // Calculate Physical Capture Resolution
        let scale = isRetina ? 2 : 1
        let captureWidth = selectedResolution.width * scale
        let captureHeight = selectedResolution.height * scale

        // Adaptive quality: P2P gets full, loopback (ADB) gets medium-high, infrastructure gets capped
        let isP2P = pipelines[connectionId]?.isP2P ?? false
        let isLoopback = pipelines[connectionId]?.isLoopback ?? false
        let fps: Int
        let bitrate: Int
        let keyframeInterval: Double
        if isP2P {
            fps = 120
            bitrate = selectedQuality.rawValue
            keyframeInterval = 10.0 // P2P is reliable, long interval is fine
        } else if isLoopback {
            let isWiFiADB = pipelines[connectionId]?.isWiFiADB ?? false
            if isWiFiADB {
                // WiFi ADB — receiver queues all frames (no drops), so 60fps is safe.
                // Bitrate capped to fit WiFi bandwidth; shorter KF interval for faster recovery.
                fps = 60
                bitrate = min(selectedQuality.rawValue, 10_000_000) // Cap at 10 Mbps
                keyframeInterval = 3.0
                LogManager.shared.log("Sender: WiFi ADB mode — \(fps) FPS / \(bitrate / 1_000_000) Mbps / KF every 3s for \(serviceName)")
            } else {
                // USB ADB — ~280Mbps, plenty of headroom
                fps = 60
                bitrate = selectedQuality.rawValue
                keyframeInterval = 10.0
                LogManager.shared.log("Sender: USB ADB mode — \(fps) FPS / \(bitrate / 1_000_000) Mbps / KF every 10s for \(serviceName)")
            }
        } else {
            // Infrastructure (WiFi router, future Linux/Windows)
            // Cap to reduce TCP congestion and jitter
            fps = 30
            bitrate = min(selectedQuality.rawValue, 10_000_000) // Cap at 10 Mbps
            keyframeInterval = 5.0  // More frequent than P2P since infrastructure has more jitter
            LogManager.shared.log("Sender: Infrastructure mode — \(fps) FPS / \(bitrate / 1_000_000) Mbps / KF every 5s for \(serviceName)")
        }

        LogManager.shared.log("Sender: Pipeline \(serviceName): \(captureWidth)x\(captureHeight) (Scale: \(scale)x) @ \(selectedQuality.name) [\(fps) FPS, P2P: \(isP2P)]")

        let encoder = VideoEncoder(connectionId: connectionId, width: captureWidth, height: captureHeight, bitrate: bitrate, expectedFPS: fps, keyframeIntervalSeconds: keyframeInterval)
        encoder.delegate = self
        pipelines[connectionId]?.videoEncoder = encoder

        // Audio encoder (if audio streaming enabled for this connection)
        let audioEnabled = connectedDisplays.first(where: { $0.id == connectionId })?.audioEnabled ?? audioStreamingEnabled
        var audioEnc: AudioEncoder? = nil
        if audioEnabled {
            let ae = AudioEncoder(connectionId: connectionId)
            ae.delegate = self
            pipelines[connectionId]?.audioEncoder = ae
            audioEnc = ae
            LogManager.shared.log("Sender: Audio encoder created for \(serviceName)")
        }

        let recorder = ScreenRecorder(
            videoEncoder: encoder,
            targetDisplayID: targetDisplayID,
            width: captureWidth,
            height: captureHeight,
            captureFPS: Int32(fps)
        )
        recorder.captureAudio = audioEnabled
        recorder.audioEncoder = audioEnc
        pipelines[connectionId]?.screenRecorder = recorder

        Task {
            await recorder.startCapture()
        }
    }
    
    // VideoEncoderDelegate - Send to the specific connection that owns this encoder
    func videoEncoder(_ encoder: VideoEncoder, didEncode data: Data, for connectionId: UUID, isKeyframe: Bool) {
        guard let pipeline = pipelines[connectionId] else { return }

        // Determine if this connection uses TCP framing (ADB/localhost always TCP, else follow global)
        let useTCP = pipeline.forceTCP || connectionType != "UDP"

        // TCP backpressure: skip P-frame if previous send still in flight
        // NEVER drop keyframes — the decoder needs them to display anything
        // ADB (USB or WiFi): NEVER drop P-frames — dropping breaks the decoder's
        // reference chain causing pixelation. Instead, we control bandwidth via
        // lower bitrate/FPS settings. TCP flow control handles the rest.
        // Only infrastructure connections use completion-based backpressure.
        if !pipeline.isP2P && !pipeline.isLoopback && useTCP && !isKeyframe {
            if pipeline.sendInProgress {
                return // Infrastructure only: completion-based backpressure
            }
        }

        if !useTCP {
            let mtu = 1000
            let headerSize = 8
            let maxPayload = mtu - headerSize

            udpFrameId &+= 1
            let thisFrameId = udpFrameId

            let totalData = data
            let totalCount = totalData.count

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

                let isLargeFrame = totalChunks > 10
                let pacingMicroseconds: useconds_t = 120

                pipeline.connection.send(content: finalPacket, completion: .contentProcessed { [weak self] error in
                    if let error = error {
                        if case let NWError.posix(code) = error {
                            switch code {
                            case .ECANCELED:
                                LogManager.shared.log("Sender: Connection to \(pipeline.service.name) canceled (Device disconnected)")
                                DispatchQueue.main.async {
                                    self?.removeConnection(connectionId)
                                }
                                return
                            case .ECONNREFUSED:
                                LogManager.shared.log("Sender: Connection refused by \(pipeline.service.name)")
                                return
                            default:
                                break
                            }
                        }
                        LogManager.shared.log("Sender: UDP Chunk Error to \(pipeline.service.name): \(error)")
                    }
                })

                if isLargeFrame && chunkIndex < totalChunks - 1 {
                    usleep(pacingMicroseconds)
                }
            }
        } else {
            // TCP: Length-prefixed framing with type byte - Send to this connection only
            // Format: [4-byte length][1-byte type: 0x01=video][payload]
            var typedPayload = Data([0x01]) // Video packet type
            typedPayload.append(data)
            var lengthPrefix = UInt32(typedPayload.count).bigEndian
            var packet = Data(bytes: &lengthPrefix, count: 4)
            packet.append(typedPayload)

            bytesSentWindow += packet.count

            // Mark send in progress for backpressure (infrastructure)
            // Track send time for ADB loopback time-based pacing
            if !pipeline.isP2P {
                pipelines[connectionId]?.sendInProgress = true
                pipelines[connectionId]?.lastSendTimeNs = DispatchTime.now().uptimeNanoseconds
            }

            pipeline.connection.send(content: packet, completion: .contentProcessed { [weak self] error in
                DispatchQueue.main.async {
                    self?.pipelines[connectionId]?.sendInProgress = false
                }
                if let error = error {
                    LogManager.shared.log("Sender: TCP Send Error to \(pipeline.service.name): \(error)")
                }
            })
        }
    }

    // AudioEncoderDelegate - Send AAC audio to the specific connection
    func audioEncoder(_ encoder: AudioEncoder, didEncode data: Data, for connectionId: UUID) {
        guard let pipeline = pipelines[connectionId] else { return }

        // Audio always uses TCP framing
        // Format: [4-byte length][1-byte type: 0x02=audio][AAC data]
        var typedPayload = Data([0x02]) // Audio packet type
        typedPayload.append(data)
        var lengthPrefix = UInt32(typedPayload.count).bigEndian
        var packet = Data(bytes: &lengthPrefix, count: 4)
        packet.append(typedPayload)

        bytesSentWindow += packet.count

        pipeline.connection.send(content: packet, completion: .contentProcessed { error in
            if let error = error {
                LogManager.shared.log("Sender: Audio send error to \(pipeline.service.name): \(error)")
            }
        })
    }
}
