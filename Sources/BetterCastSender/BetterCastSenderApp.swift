import SwiftUI
import Network
import Security
import ScreenCaptureKit
import IOKit.graphics


@main
struct BetterCastSenderApp: App {
    @StateObject private var networkClient = NetworkClient()
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some Scene {
        WindowGroup {
            if hasCompletedOnboarding {
                mainView
            } else {
                OnboardingView(onComplete: {
                    hasCompletedOnboarding = true
                })
                .frame(minWidth: 520, minHeight: 600)
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
    }

    enum SidebarSelection: Hashable {
        case devices
        case settings
        case device(UUID)
        case discovered(String) // Unconnected device by service name
        case logs
    }

    @State private var sidebarSelection: SidebarSelection? = .devices
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    private var mainView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(client: networkClient, selection: $sidebarSelection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 350)
        } detail: {
            DetailPanelView(client: networkClient, selection: $sidebarSelection, hasCompletedOnboarding: $hasCompletedOnboarding)
        }
        .frame(minWidth: 750, minHeight: 540)
        .onAppear {
            networkClient.checkScreenRecordingPermission()
            networkClient.startBrowsing()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                InputHandler.shared.checkAccessibility()
            }
        }
    }
}

// MARK: - Onboarding View

struct OnboardingView: View {
    let onComplete: () -> Void

    @State private var currentStep = 0
    @State private var screenRecordingGranted = false
    @State private var accessibilityGranted = false
    @State private var pollTimer: Timer?

    private let steps = ["Screen Recording", "Accessibility", "Ready"]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 4)

                Text("Welcome to BetterCast")
                    .font(.system(size: 26, weight: .bold))

                Text("A few permissions are needed to get started")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 40)
            .padding(.bottom, 30)

            // Step indicators
            HStack(spacing: 24) {
                ForEach(0..<steps.count, id: \.self) { index in
                    StepIndicator(
                        number: index + 1,
                        title: steps[index],
                        isActive: currentStep == index,
                        isCompleted: stepCompleted(index)
                    )
                    if index < steps.count - 1 {
                        Rectangle()
                            .fill(stepCompleted(index) ? Color.green : Color(nsColor: .separatorColor))
                            .frame(height: 2)
                            .frame(maxWidth: 40)
                    }
                }
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 30)

            // Step content
            VStack(spacing: 20) {
                switch currentStep {
                case 0:
                    screenRecordingStep
                case 1:
                    accessibilityStep
                default:
                    readyStep
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 40)

            Spacer()

            // Navigation buttons
            HStack {
                if currentStep > 0 {
                    Button("Back") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            currentStep -= 1
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }

                Spacer()

                if currentStep < 2 {
                    Button(stepCompleted(currentStep) ? "Next" : "Skip") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            currentStep += 1
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else {
                    Button("Get Started") {
                        onComplete()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.green)
                }
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 30)
        }
        .onAppear {
            checkPermissions()
            startPolling()
        }
        .onDisappear {
            pollTimer?.invalidate()
        }
    }

    // MARK: - Step Views

    private var screenRecordingStep: some View {
        PermissionStepCard(
            icon: "record.circle",
            iconColor: .red,
            title: "Screen Recording",
            description: "BetterCast needs Screen Recording permission to capture your display and stream it to receivers.",
            isGranted: screenRecordingGranted,
            actionTitle: "Open Screen Recording Settings",
            action: {
                // macOS 13+ deep link
                if let url = URL(string: "x-apple.systempreferences:com.apple.PrivacySecurity.extension?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
                // Fallback for older macOS
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            }
        )
    }

    private var accessibilityStep: some View {
        PermissionStepCard(
            icon: "hand.point.up.left",
            iconColor: .blue,
            title: "Accessibility",
            description: "Accessibility permission lets BetterCast relay mouse and keyboard input from your receivers back to this Mac.",
            isGranted: accessibilityGranted,
            actionTitle: "Open Accessibility Settings",
            action: {
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            }
        )
    }

    private var readyStep: some View {
        VStack(spacing: 16) {
            DashboardCard {
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)

                    Text("You're all set!")
                        .font(.system(size: 20, weight: .semibold))

                    VStack(alignment: .leading, spacing: 8) {
                        permissionRow("Screen Recording", granted: screenRecordingGranted)
                        permissionRow("Accessibility", granted: accessibilityGranted)
                    }
                    .padding(.top, 4)

                    if !screenRecordingGranted || !accessibilityGranted {
                        Text("Some permissions are missing. You can grant them later in System Settings, but some features won't work until they're enabled.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
        }
    }

    private func permissionRow(_ name: String, granted: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(granted ? .green : .orange)
            Text(name)
                .font(.system(size: 14))
            Spacer()
            Text(granted ? "Granted" : "Not granted")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(granted ? .green : .orange)
        }
    }

    // MARK: - Helpers

    private func stepCompleted(_ step: Int) -> Bool {
        switch step {
        case 0: return screenRecordingGranted
        case 1: return accessibilityGranted
        case 2: return true
        default: return false
        }
    }

    private func checkPermissions() {
        // Screen Recording: check via CGPreflightScreenCaptureAccess (macOS 10.15+)
        screenRecordingGranted = CGPreflightScreenCaptureAccess()

        // Accessibility: check without prompting
        accessibilityGranted = AXIsProcessTrusted()
    }

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            checkPermissions()
            // Auto-advance when permission is granted on current step
            if currentStep == 0 && screenRecordingGranted {
                withAnimation(.easeInOut(duration: 0.2)) {
                    currentStep = 1
                }
            } else if currentStep == 1 && accessibilityGranted {
                withAnimation(.easeInOut(duration: 0.2)) {
                    currentStep = 2
                }
            }
        }
    }
}

// MARK: - Step Indicator

struct StepIndicator: View {
    let number: Int
    let title: String
    let isActive: Bool
    let isCompleted: Bool

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(isCompleted ? Color.green : (isActive ? Color.accentColor : Color(nsColor: .separatorColor)))
                    .frame(width: 32, height: 32)
                if isCompleted {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(number)")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isActive ? .white : .secondary)
                }
            }
            Text(title)
                .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? .primary : .secondary)
        }
    }
}

// MARK: - Permission Step Card

struct PermissionStepCard: View {
    let icon: String
    let iconColor: Color
    let title: String
    let description: String
    let isGranted: Bool
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        DashboardCard {
            VStack(spacing: 16) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(iconColor.opacity(0.12))
                            .frame(width: 48, height: 48)
                        Image(systemName: icon)
                            .font(.system(size: 22))
                            .foregroundStyle(iconColor)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(title)
                                .font(.system(size: 16, weight: .semibold))
                            if isGranted {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                        Text(description)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if isGranted {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Permission granted")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.green)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.green.opacity(0.08))
                    )
                } else {
                    Button(action: action) {
                        HStack {
                            Image(systemName: "gear")
                            Text(actionTitle)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - Dashboard Card Container (fallback for pre-macOS 26)

struct DashboardCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 1)
            )
    }
}

extension DashboardCard {
    init(padded: Bool = true, @ViewBuilder content: () -> Content) {
        self.content = content()
    }
}

// MARK: - Sidebar (native List)

struct SidebarView: View {
    @ObservedObject var client: NetworkClient
    @Binding var selection: BetterCastSenderApp.SidebarSelection?

    var body: some View {
        List(selection: $selection) {
            // Devices first — the main dashboard
            Section("Devices") {
                Label("Overview", systemImage: "rectangle.on.rectangle")
                    .tag(BetterCastSenderApp.SidebarSelection.devices)

                if client.foundServices.isEmpty && client.connectedServices.isEmpty {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Searching...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(client.foundServices.filter { service in
                        // Hide ADB synthetic entries when the mDNS Android device is visible
                        let isADBSynthetic = service.name.contains("Android (USB)") || service.name.contains("Android (WiFi ADB)")
                        let hasMDNSAndroid = client.foundServices.contains(where: {
                            $0.name.lowercased().contains("android") && !$0.name.contains("Android (USB)") && !$0.name.contains("Android (WiFi ADB)")
                        })
                        return !(isADBSynthetic && hasMDNSAndroid)
                    }, id: \.name) { service in
                        SidebarDeviceRow(service: service, client: client)
                    }
                }

                // Connected ADB tunnels not in foundServices — but hide Android ADB
                // entries when the mDNS Android device is already shown
                ForEach(client.connectedDisplays.filter { display in
                    let inFoundServices = client.foundServices.contains(where: { $0.name == display.name })
                    let isADBDuplicate = (display.name.contains("Android (USB)") || display.name.contains("Android (WiFi ADB)"))
                        && client.foundServices.contains(where: { $0.name.lowercased().contains("android") })
                    return !inFoundServices && !isADBDuplicate
                }) { display in
                    Label {
                        VStack(alignment: .leading) {
                            Text(display.name)
                            Text(display.resolution)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "display")
                            .foregroundStyle(.green)
                    }
                    .tag(BetterCastSenderApp.SidebarSelection.device(display.id))
                }
            }

            // Manual Connect
            Section("Connect") {
                ManualConnectRow(client: client)
            }

            // Settings & Logs at the bottom
            Section {
                Label("Settings", systemImage: "gearshape")
                    .tag(BetterCastSenderApp.SidebarSelection.settings)
                Label("Logs", systemImage: "text.alignleft")
                    .tag(BetterCastSenderApp.SidebarSelection.logs)
            }
        }
        .navigationTitle("BetterCast")
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button(role: .destructive) {
                    client.quitApp()
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("Quit BetterCast")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
}

// MARK: - Sidebar Device Row

struct SidebarDeviceRow: View {
    let service: DiscoveredService
    @ObservedObject var client: NetworkClient

    private var isAndroid: Bool {
        service.name.lowercased().contains("android")
    }

    /// Connected directly (same service name) or via ADB tunnel
    private var isConnected: Bool {
        if client.connectedServices.contains(where: { $0.name == service.name }) { return true }
        // Android: also count ADB tunnel connections
        if isAndroid {
            return client.connectedDisplays.contains(where: {
                $0.name.contains("Android (USB)") || $0.name.contains("Android (WiFi ADB)")
            })
        }
        return false
    }

    /// Find the connected display ID for this device (direct or ADB)
    private var connectedDisplayId: UUID? {
        if let display = client.connectedDisplays.first(where: { $0.name == service.name }) {
            return display.id
        }
        if isAndroid {
            return client.connectedDisplays.first(where: {
                $0.name.contains("Android (USB)") || $0.name.contains("Android (WiFi ADB)")
            })?.id
        }
        return nil
    }

    /// Connection method label for connected Android devices
    private var connectionMethod: String {
        if client.connectedDisplays.contains(where: { $0.name.contains("Android (USB)") }) {
            return "Connected (USB)"
        }
        if client.connectedDisplays.contains(where: { $0.name.contains("Android (WiFi ADB)") }) {
            return "Connected (WiFi ADB)"
        }
        if client.connectedServices.contains(where: { $0.name == service.name }) {
            return "Connected (WiFi)"
        }
        return "Available"
    }

    private var deviceIcon: String {
        if isConnected { return "display" }
        if isAndroid { return "apps.iphone" }
        if service.name.lowercased().contains("windows") { return "pc" }
        if service.name.lowercased().contains("linux") { return "desktopcomputer" }
        return "display"
    }

    var body: some View {
        HStack {
            Label {
                VStack(alignment: .leading) {
                    Text(service.name)
                        .lineLimit(1)
                    Text(isAndroid ? connectionMethod : (isConnected ? "Connected" : "Available"))
                        .font(.caption)
                        .foregroundStyle(isConnected ? .green : .secondary)
                }
            } icon: {
                Image(systemName: deviceIcon)
                    .foregroundStyle(isConnected ? .green : .secondary)
            }
            Spacer()
            if !isConnected && !isAndroid {
                Button {
                    client.connect(to: service)
                } label: {
                    Image(systemName: "link")
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(.accentColor)
            }
        }
        .tag(
            isConnected
                ? connectedDisplayId.map { BetterCastSenderApp.SidebarSelection.device($0) }
                    ?? BetterCastSenderApp.SidebarSelection.discovered(service.name)
                : BetterCastSenderApp.SidebarSelection.discovered(service.name)
        )
    }
}

// MARK: - Manual Connect Row

struct ManualConnectRow: View {
    @ObservedObject var client: NetworkClient
    @State private var expanded = false

    var body: some View {
        DisclosureGroup("Manual IP", isExpanded: $expanded) {
            VStack(spacing: 8) {
                TextField("IP / hostname", text: $client.manualHost)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    TextField("Port", text: $client.manualPort)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Button("Connect") {
                        client.connectManual()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(client.manualHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

// MARK: - ADB Connect Row

struct ADBConnectRow: View {
    @ObservedObject var client: NetworkClient
    @State private var expanded = false

    var body: some View {
        DisclosureGroup("Android (ADB)", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button(client.adbInProgress ? "Setting up..." : "Wireless") {
                        client.connectADBWireless()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.green)
                    .disabled(client.adbInProgress)

                    Button("USB") {
                        client.connectADBUSB()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.blue)
                }
                if !client.adbStatus.isEmpty {
                    Text(client.adbStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Detail Panel

struct DetailPanelView: View {
    @ObservedObject var client: NetworkClient
    @Binding var selection: BetterCastSenderApp.SidebarSelection?
    @Binding var hasCompletedOnboarding: Bool

    var body: some View {
        switch selection {
        case .device(let id):
            if let display = client.connectedDisplays.first(where: { $0.id == id }) {
                DeviceDetailView(display: display, client: client, selection: $selection)
            } else {
                settingsForm
            }
        case .discovered(let name):
            if let service = client.foundServices.first(where: { $0.name == name }) {
                DiscoveredDeviceView(service: service, client: client, selection: $selection)
            } else {
                settingsForm
            }
        case .logs:
            LogView()
                .navigationTitle("Logs")
        case .settings:
            settingsForm
        case .devices, nil:
            gettingStartedView
        }
    }

    // MARK: - Settings (native Form)

    /// Discovered services that are not yet connected
    private var availableDevices: [DiscoveredService] {
        client.foundServices.filter { service in
            !client.connectedServices.contains(where: { $0.name == service.name })
        }
    }

    private var settingsForm: some View {
        Form {
            if !availableDevices.isEmpty {
                Section("Devices") {
                    ForEach(availableDevices) { service in
                        HStack {
                            Label {
                                VStack(alignment: .leading) {
                                    Text(service.name)
                                        .lineLimit(1)
                                    Text("Available")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: deviceIcon(for: service))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Connect") {
                                client.connect(to: service)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                }
            }

            Section {
                HStack {
                    Picker("Use as", selection: $client.useVirtualDisplay) {
                        Text("Extended Display").tag(true)
                        Text("Mirror Built-in").tag(false)
                    }
                    InfoTip(text: "Extended creates a separate virtual monitor. Mirror duplicates your main display.")
                }

                HStack {
                    Picker("Resolution", selection: $client.selectedResolution) {
                        ForEach(VirtualDisplayManager.defaultResolutions, id: \.self) { res in
                            Text(res.name).tag(res)
                        }
                    }
                    .disabled(!client.useVirtualDisplay)
                    InfoTip(text: "Resolution of the virtual display. Higher resolutions use more bandwidth.")
                }

                HStack {
                    Toggle("Retina (HiDPI)", isOn: $client.isRetina)
                        .disabled(!client.useVirtualDisplay)
                    InfoTip(text: "Doubles pixel density. Sharper text but uses more bandwidth.")
                }

                HStack {
                    Slider(value: $client.displayBrightness, in: 0...1, step: 0.05) {
                        Text("Brightness")
                    }
                    InfoTip(text: "Adjusts the brightness of your built-in display.")
                }

                HStack {
                    Toggle("Audio Streaming", isOn: $client.audioStreamingEnabled)
                    InfoTip(text: "Streams system audio to the receiver. Requires a compatible receiver.")
                }

                Button("Arrange Displays") {
                    client.openDisplaySettings()
                }
            } header: {
                Text("Display")
            }

            Section("Connection") {
                HStack {
                    Toggle("Auto-Connect", isOn: $client.autoConnect)
                    InfoTip(text: "Automatically connect to discovered receivers when they appear on the network.")
                }

                HStack {
                    Picker("Mode", selection: $client.interfacePreference) {
                        ForEach(NetworkInterfacePreference.allCases) { pref in
                            Text(pref.rawValue).tag(pref)
                        }
                    }
                    .disabled(client.isConnected)
                    InfoTip(text: "Auto: AWDL for Apple devices, WiFi for others. P2P: forces direct link. Router: uses your WiFi network. Cable: USB/Thunderbolt only.")
                }

                HStack {
                    Picker("Protocol", selection: $client.connectionType) {
                        Text("TCP (Recommended)").tag("TCP")
                        Text("UDP (Faster, P2P only)").tag("UDP")
                    }
                    InfoTip(text: "TCP is reliable and works everywhere. UDP has lower latency but only works over P2P/AWDL.")
                }

                HStack {
                    Picker("Quality", selection: $client.selectedQuality) {
                        ForEach(StreamQuality.allCases) { quality in
                            Text(quality.name).tag(quality)
                        }
                    }
                    InfoTip(text: "Higher quality uses more bandwidth. Use Low/Medium on WiFi, High/Ultra on P2P or cable.")
                }

                if client.isConnected {
                    LabeledContent("Transfer Speed") {
                        Text(client.transferRate)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.green)
                    }
                }
            }

            Section("Controls") {
                HStack(spacing: 10) {
                    Button("Apply Settings") {
                        if client.isConnected {
                            client.updateStreamResolution()
                        }
                    }
                    .disabled(!client.isConnected)

                    Button("Screen Recording") {
                        client.openPrivacySettings()
                    }

                    Button("Reset Permissions") {
                        client.resetScreenCapturePermissions()
                    }

                    Button("Restart") {
                        client.restartApp()
                    }

                    Button("Setup Wizard") {
                        hasCompletedOnboarding = false
                    }
                }
            }

            if !client.connectedDisplays.isEmpty {
                Section("Connected Displays") {
                    ForEach(client.connectedDisplays) { display in
                        HStack {
                            Label {
                                VStack(alignment: .leading) {
                                    Text(display.name)
                                    Text(display.resolution)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "display")
                                    .foregroundStyle(.green)
                            }
                            Spacer()
                            Button("Disconnect") {
                                client.disconnectConnection(display.id)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(.red)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }

    private func deviceIcon(for service: DiscoveredService) -> String {
        let name = service.name.lowercased()
        if name.contains("android") { return "apps.iphone" }
        if name.contains("windows") { return "pc" }
        if name.contains("linux") { return "desktopcomputer" }
        return "display"
    }

    // MARK: - Getting Started (empty state)

    private var hasAnyDevices: Bool {
        !client.foundServices.isEmpty || !client.connectedDisplays.isEmpty
    }

    private var gettingStartedView: some View {
        VStack(spacing: 0) {
            if hasAnyDevices {
                // Devices are visible in sidebar — show a nudge
                VStack(spacing: 16) {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("Select a device from the sidebar to connect")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // No devices found — onboarding empty state
                VStack(spacing: 32) {
                    Spacer()

                    // Header
                    VStack(spacing: 12) {
                        Image(systemName: "display.2")
                            .font(.system(size: 56, weight: .thin))
                            .foregroundStyle(.secondary)

                        Text("No Devices Found")
                            .font(.system(size: 24, weight: .bold))

                        Text("To use BetterCast, you need the receiver app running on another device.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 400)
                    }

                    // Steps
                    VStack(alignment: .leading, spacing: 16) {
                        gettingStartedStep(
                            number: 1,
                            title: "Download the Receiver",
                            subtitle: "Install BetterCast Receiver on your iPad, Android, Windows, Linux, or Mac."
                        )
                        gettingStartedStep(
                            number: 2,
                            title: "Connect to the Same Network",
                            subtitle: "Make sure both devices are on the same Wi-Fi network."
                        )
                        gettingStartedStep(
                            number: 3,
                            title: "Open the Receiver App",
                            subtitle: "Your device will appear automatically in the sidebar."
                        )
                    }
                    .padding(.horizontal, 40)

                    // Download button
                    Button {
                        if let url = URL(string: "https://bettercast.online/#install") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Label("Download Receiver App", systemImage: "arrow.down.circle.fill")
                            .font(.headline)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    // Searching indicator
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Searching for devices on your network...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Devices")
    }

    private func gettingStartedStep(number: Int, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.accentColor))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Unified Device View (connected + discovered)

struct DeviceDetailView: View {
    let display: ConnectedDisplayInfo
    @ObservedObject var client: NetworkClient
    @Binding var selection: BetterCastSenderApp.SidebarSelection?

    var body: some View {
        Form {
            Section("Resolution") {
                HStack {
                    Picker("Dimensions", selection: $client.selectedResolution) {
                        ForEach(VirtualDisplayManager.defaultResolutions, id: \.self) { res in
                            Text(res.name).tag(res)
                        }
                    }
                    InfoTip(text: "Resolution of the virtual display. Higher resolutions use more bandwidth.")
                }

                HStack {
                    Toggle("Retina (HiDPI)", isOn: $client.isRetina)
                    InfoTip(text: "Doubles pixel density. Sharper text but uses more bandwidth.")
                }
            }

            Section("Quality") {
                HStack {
                    Picker("Bitrate", selection: $client.selectedQuality) {
                        ForEach(StreamQuality.allCases) { quality in
                            Text(quality.name).tag(quality)
                        }
                    }
                    InfoTip(text: "Higher quality uses more bandwidth. Use Low/Medium on WiFi, High/Ultra on P2P or cable.")
                }

                HStack {
                    Toggle("Audio Streaming", isOn: Binding(
                        get: { display.audioEnabled },
                        set: { client.setAudioEnabled($0, for: display.id) }
                    ))
                    InfoTip(text: "Streams system audio to this receiver.")
                }
            }

            Section("Status") {
                LabeledContent("Current") {
                    Text(display.resolution)
                }

                if display.displayBounds != .zero {
                    LabeledContent("Position") {
                        Text("(\(Int(display.displayBounds.origin.x)), \(Int(display.displayBounds.origin.y)))")
                    }
                }

                LabeledContent("Transfer Speed") {
                    Text(client.transferRate)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.green)
                }
            }

            Section {
                HStack(spacing: 10) {
                    Button("Apply Settings") {
                        client.updateStreamResolution()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Disconnect") {
                        client.disconnectConnection(display.id)
                        selection = .settings
                    }
                    .tint(.red)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(display.name)
    }
}

struct DiscoveredDeviceView: View {
    let service: DiscoveredService
    @ObservedObject var client: NetworkClient
    @Binding var selection: BetterCastSenderApp.SidebarSelection?

    private var isAndroid: Bool {
        service.name.lowercased().contains("android")
    }

    /// Check if this device is connected via any method (direct or ADB)
    private var connectedDisplay: ConnectedDisplayInfo? {
        if let d = client.connectedDisplays.first(where: { $0.name == service.name }) { return d }
        if isAndroid {
            return client.connectedDisplays.first(where: {
                $0.name.contains("Android (USB)") || $0.name.contains("Android (WiFi ADB)")
            })
        }
        return nil
    }

    var body: some View {
        if let display = connectedDisplay {
            // Connected — show per-device settings
            DeviceDetailView(display: display, client: client, selection: $selection)
        } else {
            // Not connected — show connect options
            connectForm
        }
    }

    private var connectForm: some View {
        Form {
            Section("Connect") {
                if isAndroid {
                    HStack {
                        Image(systemName: "cable.connector")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            Text("ADB (USB)")
                                .fontWeight(.medium)
                            Text("60 FPS — best quality, requires USB cable")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Connect") {
                            client.connectADBUSB()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        InfoTip(text: "Streams via USB using Android Debug Bridge. Highest quality with no network needed. Plug in your Android device first.")
                    }

                    HStack {
                        Image(systemName: "wifi")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            Text("ADB (WiFi)")
                                .fontWeight(.medium)
                            Text("60 FPS — wireless ADB tunnel, needs USB first")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Connect") {
                            client.connectADBWireless()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(client.adbInProgress)
                        InfoTip(text: "Wireless ADB tunnel. Connect USB once to pair, then unplug and stream wirelessly at full quality.")
                    }
                }

                HStack {
                    Image(systemName: "network")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading) {
                        Text("WiFi (TCP)")
                            .fontWeight(.medium)
                        Text(isAndroid ? "30 FPS — direct network, no ADB needed" : "Connect via network")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Connect") {
                        client.connect(to: service)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    InfoTip(text: isAndroid ? "Connects directly over WiFi without ADB. Lower FPS but no USB setup required." : "Connects over your local network. Apple devices use AWDL peer-to-peer when available for best performance.")
                }
            }

            if isAndroid && !client.adbStatus.isEmpty {
                Section("ADB Status") {
                    Text(client.adbStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Resolution") {
                HStack {
                    Picker("Dimensions", selection: $client.selectedResolution) {
                        ForEach(VirtualDisplayManager.defaultResolutions, id: \.self) { res in
                            Text(res.name).tag(res)
                        }
                    }
                    InfoTip(text: "Resolution of the virtual display. Higher resolutions use more bandwidth.")
                }

                HStack {
                    Toggle("Retina (HiDPI)", isOn: $client.isRetina)
                    InfoTip(text: "Doubles pixel density. Sharper text but uses more bandwidth.")
                }
            }

            Section("Quality") {
                HStack {
                    Picker("Bitrate", selection: $client.selectedQuality) {
                        ForEach(StreamQuality.allCases) { quality in
                            Text(quality.name).tag(quality)
                        }
                    }
                    InfoTip(text: "Higher quality uses more bandwidth. Use Low/Medium on WiFi, High/Ultra on P2P or cable.")
                }

                HStack {
                    Toggle("Audio Streaming", isOn: $client.audioStreamingEnabled)
                    InfoTip(text: "Streams system audio to the receiver. Requires a compatible receiver.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(service.name)
    }
}

// MARK: - Display Brightness Control

enum DisplayBrightnessControl {
    static func setBrightness(_ brightness: Double) {
        let value = max(0, min(1, brightness))
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iterator)
        guard result == kIOReturnSuccess else { return }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            IODisplaySetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, Float(value))
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
    }

    static func getBrightness() -> Double {
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iterator)
        guard result == kIOReturnSuccess else { return 0.5 }
        defer { IOObjectRelease(iterator) }

        var brightness: Float = 0.5
        let service = IOIteratorNext(iterator)
        if service != 0 {
            IODisplayGetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, &brightness)
            IOObjectRelease(service)
        }
        return Double(brightness)
    }
}

// MARK: - Info Tip

struct InfoTip: View {
    let text: String
    @State private var isShowing = false

    var body: some View {
        Button {
            isShowing.toggle()
        } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isShowing, arrowEdge: .trailing) {
            Text(text)
                .font(.caption)
                .padding(10)
                .frame(maxWidth: 260)
                .fixedSize(horizontal: false, vertical: true)
        }
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

// MARK: - Connected Display Info

struct ConnectedDisplayInfo: Identifiable {
    let id: UUID
    let name: String
    let resolution: String
    let displayBounds: CGRect
    var audioEnabled: Bool
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
    // iOS/Mac Swift receivers don't strip the type byte — send raw payloads for them
    var supportsTypeByte: Bool = true
}

class NetworkClient: ObservableObject, VideoEncoderDelegate, AudioEncoderDelegate {
    private var browser: NWBrowser?
    private var pipelines: [UUID: ConnectionPipeline] = [:]

    @Published var status: String = "Idle"
    @Published var foundServices: [DiscoveredService] = []
    @Published var connectedServices: [DiscoveredService] = []
    private var connectingServiceNames: Set<String> = [] // Prevent double-connect race
    @Published var useVirtualDisplay: Bool = true // Toggle between mirroring and extended display
    @Published var audioStreamingEnabled: Bool = false // Master toggle for audio streaming
    @Published var displayBrightness: Float = Float(DisplayBrightnessControl.getBrightness()) {
        didSet { DisplayBrightnessControl.setBrightness(Double(displayBrightness)) }
    }
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

    // Auto-connect: automatically connect to discovered receivers
    @Published var autoConnect: Bool = false

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

                // Auto-connect to newly discovered services
                if self.autoConnect {
                    for service in services {
                        if !self.connectedServices.contains(where: { $0.name == service.name })
                            && !self.connectingServiceNames.contains(service.name) {
                            // Skip ADB synthetic entries
                            if service.name.contains("Android (USB)") || service.name.contains("Android (WiFi ADB)") { continue }
                            LogManager.shared.log("Sender: Auto-connecting to \(service.name)")
                            self.connect(to: service)
                        }
                    }
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
        LogManager.shared.log("Sender: App Starting - Version v1 (Sync)")
        
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
        // Check if already connected or currently connecting to this service
        if connectedServices.contains(where: { $0.name == service.name }) {
            LogManager.shared.log("Sender: Already connected to \(service.name)")
            return
        }
        if connectingServiceNames.contains(service.name) {
            LogManager.shared.log("Sender: Already connecting to \(service.name) — ignoring duplicate")
            return
        }
        connectingServiceNames.insert(service.name)

        let deviceCount = pipelines.count + 1
        self.status = "Connecting to \(service.name) (Device #\(deviceCount))..."

        // Smart routing: Apple receivers (iOS/Mac) get P2P/AWDL, others get infrastructure
        let nameLower = service.name.lowercased()
        let isAppleReceiver = !nameLower.contains("android") && !nameLower.contains("windows") && !nameLower.contains("linux")

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

        if isAppleReceiver {
            // Apple devices: force P2P/AWDL for best quality
            parameters.includePeerToPeer = true
            if let awdl = cachedAWDLInterface {
                parameters.requiredInterface = awdl
                LogManager.shared.log("Sender: Apple receiver — forcing AWDL (\(awdl.name)) for \(service.name)")
            } else {
                // AWDL not cached yet — ban infra to force AWDL negotiation
                if let infra = cachedInfraInterface {
                    LogManager.shared.log("Sender: Apple receiver — banning infra (\(infra.name)) to force AWDL for \(service.name)")
                    parameters.prohibitedInterfaces = [infra]
                } else {
                    LogManager.shared.log("Sender: Apple receiver — no interfaces cached, using Auto for \(service.name)")
                }
                parameters.prohibitedInterfaceTypes = [.loopback, .wiredEthernet]
                parameters.serviceClass = .interactiveVideo
            }
        } else {
            // Non-Apple devices: skip P2P, go straight to infrastructure
            parameters.includePeerToPeer = false
            parameters.serviceClass = .interactiveVideo
            LogManager.shared.log("Sender: Non-Apple receiver — using infrastructure for \(service.name)")
        }

        let connection = NWConnection(to: service.endpoint, using: parameters)
        let connectionId = UUID()

        // Timeout: if connection is still not ready after 5s, retry without P2P
        // This handles cases where AWDL negotiation hangs
        var connectionTimedOut = false
        let timeoutWork = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            // Only retry if still not connected (no pipeline created yet)
            if self.pipelines[connectionId] == nil && !connectionTimedOut {
                connectionTimedOut = true
                self.connectingServiceNames.remove(service.name)
                LogManager.shared.log("Sender: Connection to \(service.name) timed out — retrying via infrastructure")
                connection.cancel()

                // Retry with plain TCP (no interface restrictions)
                let tcpOptions = NWProtocolTCP.Options()
                tcpOptions.enableKeepalive = true
                tcpOptions.noDelay = true
                tcpOptions.connectionTimeout = 10
                let fallbackParams = NWParameters(tls: nil, tcp: tcpOptions)
                fallbackParams.serviceClass = .interactiveVideo
                self.connectWithParameters(service: service, parameters: fallbackParams, forceTCP: false)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeoutWork)

        connection.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    timeoutWork.cancel() // Connection succeeded, cancel timeout
                    self?.connectingServiceNames.remove(service.name)

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
                    // iOS/Mac Swift receivers don't handle the type byte in TCP framing
                    let isLegacyReceiver = service.name == "BetterCast Receiver" || service.name == "BetterCast Receiver iOS"
                    pipeline.supportsTypeByte = !isLegacyReceiver
                    self?.pipelines[connectionId] = pipeline
                    self?.connectedServices.append(service)
                    self?.updateConnectedDisplays()

                    let count = self?.pipelines.count ?? 0
                    self?.status = "Connected to \(count) device(s)"
                    LogManager.shared.log("Sender: Connected to \(service.name) (Total: \(count), P2P: \(isP2P), typeByte: \(pipeline.supportsTypeByte))")

                    // Start per-connection pipeline (each device gets its own display/encoder/recorder)
                    self?.startPipeline(for: connectionId)

                    // Start shared services on first connection
                    if count == 1 {
                        self?.startHeartbeatMonitor()
                        self?.startStatsTimer()
                    }

                    self?.receive(on: connection, connectionId: connectionId)
                case .failed(let error):
                    timeoutWork.cancel()
                    self?.connectingServiceNames.remove(service.name)
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
                    // iOS/Mac Swift receivers don't handle the type byte in TCP framing
                    // Android and desktop (C++/Qt) receivers do strip it
                    let isLegacyReceiver = service.name == "BetterCast Receiver" || service.name == "BetterCast Receiver iOS"
                    pipeline.supportsTypeByte = !isLegacyReceiver
                    self?.pipelines[connectionId] = pipeline
                    self?.connectedServices.append(service)
                    self?.updateConnectedDisplays()

                    let count = self?.pipelines.count ?? 0
                    self?.status = "Connected to \(count) device(s)"
                    LogManager.shared.log("Sender: Connected to \(service.name) (Total: \(count), P2P: \(isP2P), typeByte: \(pipeline.supportsTypeByte))")

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

    func openDisplaySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") {
            NSWorkspace.shared.open(url)
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
    private var updateDebounceWork: DispatchWorkItem?

    func updateStreamResolution() {
        // Debounce: cancel any pending update and schedule a new one
        updateDebounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.performUpdateStreamResolution()
        }
        updateDebounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func performUpdateStreamResolution() {
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
    private var encodedFrameCount: Int = 0

    func videoEncoder(_ encoder: VideoEncoder, didEncode data: Data, for connectionId: UUID, isKeyframe: Bool) {
        guard let pipeline = pipelines[connectionId] else { return }

        encodedFrameCount += 1
        if encodedFrameCount <= 3 || encodedFrameCount % 300 == 0 {
            LogManager.shared.log("Sender: Sending frame #\(encodedFrameCount) (\(data.count) bytes, KF: \(isKeyframe), sendInProgress: \(pipeline.sendInProgress)) to \(pipeline.service.name)")
        }

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
            // TCP: Length-prefixed framing - Send to this connection only
            var packet = Data()
            if pipeline.supportsTypeByte {
                // Format: [4-byte length][1-byte type: 0x01=video][payload]
                var typedPayload = Data([0x01])
                typedPayload.append(data)
                var lengthPrefix = UInt32(typedPayload.count).bigEndian
                packet.append(Data(bytes: &lengthPrefix, count: 4))
                packet.append(typedPayload)
            } else {
                // Legacy format: [4-byte length][payload] (iOS/Mac Swift receivers)
                var lengthPrefix = UInt32(data.count).bigEndian
                packet.append(Data(bytes: &lengthPrefix, count: 4))
                packet.append(data)
            }

            bytesSentWindow += packet.count

            // Mark send in progress for backpressure (infrastructure)
            // Track send time for ADB loopback time-based pacing
            if !pipeline.isP2P {
                pipelines[connectionId]?.sendInProgress = true
                pipelines[connectionId]?.lastSendTimeNs = DispatchTime.now().uptimeNanoseconds
            }

            pipeline.connection.send(content: packet, completion: .contentProcessed { [weak self] error in
                DispatchQueue.main.async { [weak self] in
                    // Always clear backpressure — if pipeline was removed, this is a no-op
                    self?.pipelines[connectionId]?.sendInProgress = false
                }
                if let error = error {
                    LogManager.shared.log("Sender: TCP Send Error to \(pipeline.service.name): \(error)")
                    // Clear backpressure on error too, so future frames aren't permanently blocked
                    DispatchQueue.main.async { [weak self] in
                        self?.pipelines[connectionId]?.sendInProgress = false
                    }
                }
            })
        }
    }

    // AudioEncoderDelegate - Send AAC audio to the specific connection
    func audioEncoder(_ encoder: AudioEncoder, didEncode data: Data, for connectionId: UUID) {
        guard let pipeline = pipelines[connectionId] else { return }

        // Legacy receivers (iOS/Mac Swift) don't support audio — skip
        guard pipeline.supportsTypeByte else { return }

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
