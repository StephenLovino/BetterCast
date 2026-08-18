import SwiftUI
import Network
import Security
import CoreImage.CIFilterBuiltins
import ScreenCaptureKit
import IOKit.graphics


@main
struct BetterCastSenderApp: App {
    @StateObject private var networkClient = NetworkClient()
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("hasCompletedTour") private var hasCompletedTour = false

    /// Whether the donation nudge is on screen right now.
    ///
    /// Decided in `init`, not in a `.task` on the root view: the scene's content is
    /// behind an `if`, and the task attached there never fired — the launch counter
    /// stayed unset and the sheet never appeared. `init` runs exactly once per process,
    /// which is the definition of "per launch" anyway.
    @State private var showDonatePrompt: Bool

    init() {
        _showDonatePrompt = State(initialValue: DonatePromptState.shouldPresentOnLaunch())
    }

    var body: some Scene {
        WindowGroup {
            if hasCompletedOnboarding {
                mainView
                    .sheet(isPresented: $showDonatePrompt) {
                        DonatePromptView(
                            onLater: { showDonatePrompt = false },
                            onAlreadyDonated: {
                                DonatePromptState.silenced = true
                                showDonatePrompt = false
                            }
                        )
                    }
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
        case receive
        case settings
        case device(UUID)
        case discovered(String) // Unconnected device by service name
        case logs
    }

    @State private var sidebarSelection: SidebarSelection? = .devices
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var showTour = false

    private var mainView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(client: networkClient, selection: $sidebarSelection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 350)
        } detail: {
            DetailPanelView(client: networkClient, selection: $sidebarSelection, hasCompletedOnboarding: $hasCompletedOnboarding)
        }
        .frame(minWidth: 750, minHeight: 540)
        .overlay {
            if showTour {
                GuidedTourOverlay(
                    selection: $sidebarSelection,
                    onDismiss: {
                        withAnimation { showTour = false }
                        hasCompletedTour = true
                    }
                )
                .transition(.opacity)
            }
        }
        .onAppear {
            networkClient.checkScreenRecordingPermission()
            networkClient.startBrowsing()
            networkClient.startSenderInviteListener()
            // Auto-start receiver so incoming connections work immediately
            let receiver = ReceiverManager.shared
            if !receiver.isRunning {
                receiver.start()
            }
            UpdateChecker.shared.checkForUpdates()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                InputHandler.shared.checkAccessibility()
            }
            if !hasCompletedTour {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    withAnimation { showTour = true }
                }
            }
        }
        .onChange(of: hasCompletedTour) { completed in
            if !completed {
                sidebarSelection = .devices
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    withAnimation { showTour = true }
                }
            }
        }
    }
}

// MARK: - Tour Anchor Store (global coordinates)

/// Stores sidebar item frames in global coordinate space for the tour spotlight.
class TourAnchorStore: ObservableObject {
    static let shared = TourAnchorStore()
    @Published var globalFrames: [String: CGRect] = [:]
    @Published var overlayOrigin: CGPoint = .zero

    /// Returns the frame of a tour anchor relative to the overlay.
    func frame(for key: String) -> CGRect? {
        guard let gf = globalFrames[key] else { return nil }
        return CGRect(
            x: gf.minX - overlayOrigin.x,
            y: gf.minY - overlayOrigin.y,
            width: gf.width,
            height: gf.height
        )
    }
}

extension View {
    /// Tags this view so the guided tour can spotlight it.
    func tourAnchor(_ key: String) -> some View {
        self.background(
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        TourAnchorStore.shared.globalFrames[key] = geo.frame(in: .global)
                    }
                    .onChange(of: geo.frame(in: .global).origin.x) { _ in
                        TourAnchorStore.shared.globalFrames[key] = geo.frame(in: .global)
                    }
                    .onChange(of: geo.frame(in: .global).origin.y) { _ in
                        TourAnchorStore.shared.globalFrames[key] = geo.frame(in: .global)
                    }
            }
        )
    }
}

// MARK: - Guided Tour

struct TourStep {
    let title: LocalizedStringKey
    let description: LocalizedStringKey
    let icon: String
    let sidebarTarget: BetterCastSenderApp.SidebarSelection?
    let anchorKey: String?  // key into TourAnchorKey dict to spotlight
}

struct GuidedTourOverlay: View {
    @Binding var selection: BetterCastSenderApp.SidebarSelection?
    @ObservedObject var anchorStore: TourAnchorStore = .shared
    let onDismiss: () -> Void
    @State private var currentStep = 0

    private let steps: [TourStep] = [
        TourStep(
            title: "Welcome to BetterCast",
            description: "Let's take a quick tour of the app. BetterCast turns any device into a wireless extended display for your Mac.",
            icon: "hand.wave.fill",
            sidebarTarget: nil,
            anchorKey: nil
        ),
        TourStep(
            title: "Overview",
            description: "This is your dashboard. See all connected displays with live previews, manage connections, and use \"Arrange...\" to position displays in System Settings.",
            icon: "rectangle.on.rectangle",
            sidebarTarget: .devices,
            anchorKey: "sidebar_overview"
        ),
        TourStep(
            title: "Device Settings",
            description: "Click any connected device in the sidebar to adjust resolution, bitrate, Retina mode, and audio streaming for that specific display.",
            icon: "gearshape",
            sidebarTarget: .devices,
            anchorKey: "sidebar_devices_section"
        ),
        TourStep(
            title: "Receive Screen",
            description: "BetterCast can also receive streams from other Macs. Start listening here and incoming video opens in a separate window.",
            icon: "display.and.arrow.down",
            sidebarTarget: .receive,
            anchorKey: "sidebar_receive"
        ),
        TourStep(
            title: "Settings",
            description: "Configure global preferences like connection mode, auto-connect, and manage connected displays.",
            icon: "gearshape.2",
            sidebarTarget: .settings,
            anchorKey: "sidebar_settings"
        ),
        TourStep(
            title: "Logs",
            description: "View detailed connection and streaming logs for troubleshooting. Useful if something isn't working right.",
            icon: "text.alignleft",
            sidebarTarget: .logs,
            anchorKey: "sidebar_logs"
        ),
        TourStep(
            title: "You're All Set!",
            description: "Connect a receiver device from the sidebar or use \"Receive Screen\" to receive from another Mac. Enjoy your extended display!",
            icon: "checkmark.circle.fill",
            sidebarTarget: .devices,
            anchorKey: nil
        ),
    ]

    var body: some View {
        let step = steps[currentStep]
        let spotlightRect = step.anchorKey.flatMap { anchorStore.frame(for: $0) }

        GeometryReader { geo in
            let size = geo.size

            ZStack {
                // Dimmed background with spotlight cutout
                SpotlightCutoutShape(spotlight: spotlightRect, cornerRadius: 8)
                    .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
                    .onTapGesture { }

                // Highlight border around the spotlighted item
                if let rect = spotlightRect {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.accentColor, lineWidth: 2)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.accentColor.opacity(0.08))
                        )
                        .frame(width: rect.width + 12, height: rect.height + 6)
                        .position(x: rect.midX, y: rect.midY)
                }

                // Tour card — positioned near the spotlight or centered
                tourCard
                    .frame(maxWidth: 380)
                    .position(cardPosition(in: size, spotlight: spotlightRect))
            }
            .onAppear {
                anchorStore.overlayOrigin = CGPoint(
                    x: geo.frame(in: .global).minX,
                    y: geo.frame(in: .global).minY
                )
            }
        }
        .animation(.easeInOut(duration: 0.35), value: currentStep)
        .onChange(of: currentStep) { _ in
            if let target = steps[currentStep].sidebarTarget {
                withAnimation(.easeInOut(duration: 0.2)) {
                    selection = target
                }
            }
        }
    }

    /// Positions the card to the right of the spotlight, or centered if no spotlight.
    private func cardPosition(in size: CGSize, spotlight: CGRect?) -> CGPoint {
        guard let spot = spotlight else {
            return CGPoint(x: size.width / 2, y: size.height / 2)
        }

        let cardWidth: CGFloat = 380
        let cardHeight: CGFloat = 260
        let padding: CGFloat = 20

        // Try to place to the right of the spotlight
        let rightX = spot.maxX + padding + cardWidth / 2
        let leftX = spot.minX - padding - cardWidth / 2

        let x: CGFloat
        if rightX + cardWidth / 2 < size.width {
            x = rightX
        } else if leftX - cardWidth / 2 > 0 {
            x = leftX
        } else {
            x = size.width / 2
        }

        // Vertically align with spotlight center, clamped to window
        let y = min(max(spot.midY, cardHeight / 2 + 20), size.height - cardHeight / 2 - 20)

        return CGPoint(x: x, y: y)
    }

    private var tourCard: some View {
        let step = steps[currentStep]

        return VStack(spacing: 16) {
            Image(systemName: step.icon)
                .font(.system(size: 36))
                .foregroundColor(.accentColor)
                .padding(.top, 8)

            Text(step.title)
                .font(.system(size: 18, weight: .bold))

            Text(step.description)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            // Progress dots
            HStack(spacing: 6) {
                ForEach(0..<steps.count, id: \.self) { i in
                    Circle()
                        .fill(i == currentStep ? Color.accentColor : Color.gray.opacity(0.4))
                        .frame(width: 7, height: 7)
                }
            }
            .padding(.top, 4)

            // Navigation
            HStack {
                if currentStep > 0 {
                    Button("Back") {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            currentStep -= 1
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }

                Spacer()

                Button("Skip Tour") {
                    onDismiss()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.system(size: 12))

                Spacer()

                if currentStep < steps.count - 1 {
                    Button("Next") {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            currentStep += 1
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                } else {
                    Button("Done") {
                        onDismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .tint(.green)
                }
            }
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
        )
    }
}

/// Shape that fills the entire rect but cuts out a rounded-rect spotlight hole.
struct SpotlightCutoutShape: Shape {
    var spotlight: CGRect?
    var cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        if let spot = spotlight {
            // Add the cutout as a second subpath and rely on the even-odd fill rule
            // (FillStyle(eoFill: true) at the fill site) to punch the hole. This avoids
            // Path.subtracting(_:eoFill:), which is only available on macOS 14+.
            path.addPath(Path(roundedRect: spot.insetBy(dx: -6, dy: -6), cornerRadius: cornerRadius))
        }
        return path
    }
}

// MARK: - Onboarding View

struct OnboardingView: View {
    let onComplete: () -> Void

    @State private var currentStep = 0
    @State private var screenRecordingGranted = false
    @State private var accessibilityGranted = false
    @State private var pollTimer: Timer?

    private let steps: [LocalizedStringKey] = ["Screen Recording", "Accessibility", "Ready"]

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

    private func permissionRow(_ name: LocalizedStringKey, granted: Bool) -> some View {
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
    let title: LocalizedStringKey
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
    let title: LocalizedStringKey
    let description: LocalizedStringKey
    let isGranted: Bool
    let actionTitle: LocalizedStringKey
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
        List {
            // Devices first — the main dashboard
            Section("Devices") {
                sidebarRow(tr("Overview"), icon: "rectangle.on.rectangle", tag: .devices)
                    .tourAnchor("sidebar_overview")

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
                        let isADBSynthetic = service.name.contains("Android (USB)") || service.name.contains("Android (WiFi ADB)")
                        let hasMDNSAndroid = client.foundServices.contains(where: {
                            $0.name.lowercased().contains("android") && !$0.name.contains("Android (USB)") && !$0.name.contains("Android (WiFi ADB)")
                        })
                        // Hide " P2P" entry when base device exists (merged into one entry)
                        let isP2PDuplicate = service.name.hasSuffix(" P2P")
                            && client.foundServices.contains(where: { $0.name == String(service.name.dropLast(4)) })
                        return !(isADBSynthetic && hasMDNSAndroid) && !isP2PDuplicate
                    }, id: \.name) { service in
                        SidebarDeviceRow(service: service, client: client, selection: $selection)
                    }
                }

                // Connected ADB tunnels not in foundServices
                ForEach(client.connectedDisplays.filter { display in
                    let inFoundServices = client.foundServices.contains(where: { $0.name == display.name })
                    let isADBDuplicate = (display.name.contains("Android (USB)") || display.name.contains("Android (WiFi ADB)"))
                        && client.foundServices.contains(where: { $0.name.lowercased().contains("android") })
                    // Hide " P2P" connected entry when base device is also connected
                    let isP2PConnected = display.name.hasSuffix(" P2P")
                        && client.connectedDisplays.contains(where: { $0.name == String(display.name.dropLast(4)) })
                    return !inFoundServices && !isADBDuplicate && !isP2PConnected
                }) { display in
                    sidebarRow(display.name, subtitle: display.resolution, icon: "display", tag: .device(display.id), iconTint: .green)
                }
            }
            .tourAnchor("sidebar_devices_section")

            // Manual Connect
            Section("Connect") {
                ManualConnectRow(client: client)
                QRPairRow(client: client)
                HotspotJoinRow(client: client)
            }

            // Receive mode
            Section("Receive") {
                sidebarRow(tr("Receive Screen"), icon: "display.and.arrow.down", tag: .receive)
                    .tourAnchor("sidebar_receive")
            }

            // Settings & Logs at the bottom
            Section {
                sidebarRow(tr("Settings"), icon: "gearshape", tag: .settings)
                    .tourAnchor("sidebar_settings")
                sidebarRow(tr("Logs"), icon: "text.alignleft", tag: .logs)
                    .tourAnchor("sidebar_logs")
            }
        }
        .navigationTitle("BetterCast")
        .listStyle(.sidebar)
        .sheet(isPresented: Binding(
            get: { client.qrPairingPayload != nil },
            set: { if !$0 { client.cancelQRPairing() } }
        )) {
            QRPairingSheet(client: client)
        }
        .sheet(isPresented: $client.showHotspotScanner) {
            HotspotScanSheet(client: client)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 6) {
                Button {
                    if let url = URL(string: BCConstants.donateURL) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label(tr("Support BetterCast"), systemImage: "heart.fill")
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(tr("BetterCast is free — chip in if it saved you buying a monitor"))

                HStack(spacing: 4) {
                    Button {
                        if let url = URL(string: BCConstants.authorGitHubURL) {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Text("Made with \u{2764}\u{FE0F} by Stephen Lovino")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .buttonStyle(.plain)
                    .onHover { inside in
                        if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
                    .help("Open github.com/StephenLovino")

                    Spacer(minLength: 4)

                    Button(role: .destructive) {
                        client.quitApp()
                    } label: {
                        Image(systemName: "power")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .help("Quit BetterCast")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    // Apple Music-style sidebar row: tinted icon+text when selected, subtle matte bg
    @ViewBuilder
    private func sidebarRow(
        _ title: String,
        subtitle: String? = nil,
        icon: String,
        tag: BetterCastSenderApp.SidebarSelection,
        iconTint: Color? = nil
    ) -> some View {
        let isSelected = selection == tag
        let tint = iconTint ?? .accentColor

        Button {
            selection = tag
        } label: {
            Label {
                if let subtitle = subtitle {
                    VStack(alignment: .leading) {
                        Text(title)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(isSelected ? tint.opacity(0.7) : .secondary)
                    }
                } else {
                    Text(title)
                }
            } icon: {
                Image(systemName: icon)
                    .foregroundColor(isSelected ? tint : .secondary)
            }
            .foregroundColor(isSelected ? tint : .primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            isSelected
                ? RoundedRectangle(cornerRadius: 6)
                    .fill(tint.opacity(0.1))
                : nil
        )
    }
}

// MARK: - Sidebar Device Row

struct SidebarDeviceRow: View {
    let service: DiscoveredService
    @ObservedObject var client: NetworkClient
    @Binding var selection: BetterCastSenderApp.SidebarSelection?

    private var isAndroid: Bool {
        service.name.lowercased().contains("android")
    }

    /// The synthetic row offered when a phone is plugged in but not discoverable.
    private var isUSBSynthetic: Bool {
        service.name == "Android (USB)"
    }

    /// Connected directly (same service name or " P2P" sibling) or via ADB tunnel
    private var isConnected: Bool {
        if client.isConnectedConsideringP2P(serviceName: service.name) { return true }
        // Android: also count ADB tunnel connections
        if isAndroid {
            return client.connectedDisplays.contains(where: {
                $0.name.contains("Android (USB)") || $0.name.contains("Android (WiFi ADB)")
            })
        }
        return false
    }

    /// Find the connected display ID for this device (direct, " P2P" sibling, or ADB)
    private var connectedDisplayId: UUID? {
        let base = service.name.hasSuffix(" P2P") ? String(service.name.dropLast(4)) : service.name
        let p2p = "\(base) P2P"
        if let display = client.connectedDisplays.first(where: {
            $0.name == service.name || $0.name == base || $0.name == p2p
        }) {
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
            return tr("Connected (USB)")
        }
        if client.connectedDisplays.contains(where: { $0.name.contains("Android (WiFi ADB)") }) {
            return tr("Connected (WiFi ADB)")
        }
        if client.isConnectedConsideringP2P(serviceName: service.name) {
            return tr("Connected (WiFi)")
        }
        if client.connectingUINames.contains(service.name) {
            return tr("Connecting…")
        }
        return tr("Available")
    }

    private var deviceIcon: String {
        if isConnected { return "display" }
        if isAndroid { return "apps.iphone" }
        if service.name.lowercased().contains("windows") { return "pc" }
        if service.name.lowercased().contains("linux") { return "desktopcomputer" }
        return "display"
    }

    private var rowTag: BetterCastSenderApp.SidebarSelection {
        isConnected
            ? connectedDisplayId.map { .device($0) } ?? .discovered(service.name)
            : .discovered(service.name)
    }

    private var isSelected: Bool { selection == rowTag }

    /// Split out of `body` so the row stays cheap for the type-checker.
    @ViewBuilder
    private var trailingControls: some View {
        if !isConnected {
            if isUSBSynthetic {
                // USB tunnel: loopback via ADB, works with no network at all.
                Button { client.connectADBUSB() } label: {
                    Image(systemName: "cable.connector")
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(.accentColor)
                .help(tr("Connect over USB"))
            } else if !isAndroid {
                Button { client.connect(to: service) } label: {
                    Image(systemName: "link")
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(.accentColor)
            }
        }
        Button { client.removeService(service) } label: {
            Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        .controlSize(.mini)
        .foregroundStyle(.secondary)
        .help(tr("Remove from list. Stale entries can linger after a device drops off the network."))
    }

    var body: some View {
        Button {
            selection = rowTag
        } label: {
            HStack {
                Label {
                    VStack(alignment: .leading) {
                        Text(service.name)
                            .lineLimit(1)
                        Text(isAndroid ? connectionMethod : (isConnected ? tr("Connected") : tr("Available")))
                            .font(.caption)
                            .foregroundStyle(isConnected ? .green : .secondary)
                    }
                } icon: {
                    Image(systemName: deviceIcon)
                        .foregroundColor(isSelected ? .accentColor : (isConnected ? .green : .secondary))
                }
                .foregroundColor(isSelected ? .accentColor : .primary)
                Spacer()
                trailingControls
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                client.removeService(service)
            } label: {
                Label(tr("Remove from list"), systemImage: "trash")
            }
        }
        .listRowBackground(
            isSelected
                ? RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.1))
                : nil
        )
    }
}

// MARK: - Hotspot Join Row

/// Join a hotspot hosted by the phone. The last resort when there is no shared
/// network at all: macOS cannot host one, so the phone does and the Mac joins.
struct HotspotJoinRow: View {
    @ObservedObject var client: NetworkClient
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text("On the phone, tap Create Hotspot and type what it shows here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Network name", text: $client.hotspotSSID)
                    .textFieldStyle(.roundedBorder)
                SecureField("Password", text: $client.hotspotPassword)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Join") { client.joinHotspot() }
                        .disabled(client.hotspotJoining || client.hotspotSSID.isEmpty)
                    if client.hotspotJoining { ProgressView().scaleEffect(0.5) }
                }
                Divider()
                Button {
                    client.showHotspotScanner = true
                } label: {
                    Label(tr("Scan QR from phone"), systemImage: "qrcode.viewfinder")
                }
                .help(tr("Point your Mac's camera at the QR shown on the phone to fill these in automatically."))
                Divider()
                // Works whenever you are already on the phone's hotspot, however
                // you joined it — the phone is the gateway, so no discovery needed.
                Button("Connect to Gateway") { client.connectToGateway() }
                    .help(tr("Connect straight to whichever device is hosting this network. Use when already on the phone's hotspot."))
                if !client.hotspotJoinStatus.isEmpty {
                    Text(client.hotspotJoinStatus)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Your Mac loses internet while on a phone hotspot.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } label: {
            Text(tr("Join Hotspot"))
        }
        .help(tr("Connect with no router at all. The phone hosts a local hotspot and the Mac joins it."))
    }
}

// MARK: - QR Pair Row

/// Sidebar entry for wireless ADB pairing.
///
/// Deliberately lives beside Manual IP rather than inside a device's detail view:
/// the phone has no reason to be discoverable yet. BetterCast may not even be
/// running on it, so there would be no row to click through.
struct QRPairRow: View {
    @ObservedObject var client: NetworkClient

    var body: some View {
        Button {
            client.startQRPairing()
        } label: {
            HStack {
                Label {
                    VStack(alignment: .leading) {
                        Text(tr("Pair with QR"))
                        Text(client.hasNetworkPath
                             ? tr("Android over Wi-Fi, no cable")
                             : tr("Network required"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "qrcode")
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!client.hasNetworkPath || client.adbInProgress)
        .opacity(client.hasNetworkPath ? 1 : 0.5)
        .help(tr("Pair an Android phone over Wi-Fi by scanning a code with its own camera. No USB cable needed. Android 11 or later."))
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
    @AppStorage("hasCompletedTour") private var hasCompletedTour = false

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
        case .receive:
            ReceiverModeView()
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

    /// Discovered services that are not yet connected (matches by name or " P2P" sibling)
    private var availableDevices: [DiscoveredService] {
        client.foundServices.filter { service in
            !client.isConnectedConsideringP2P(serviceName: service.name)
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
                    InfoTip(text: "Renders the virtual display at 2x so text is sharper. Apple receivers report their screen size and stream at their true native resolution; other devices stream at the resolution selected above, downsampled from the 2x framebuffer.")
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

                HStack {
                    Toggle("Compatibility Mode", isOn: $client.useLegacyCapture)
                    InfoTip(text: "Uses legacy display capture to bypass DRM/HDCP blocking (Netflix, Apple TV). May use more CPU and disables audio streaming. Only works when mirroring a physical display.")
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
                            Text(pref.displayName).tag(pref)
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

                HStack {
                    Picker("Codec", selection: $client.selectedCodec) {
                        Text("H.264").tag(StreamCodec.h264)
                        Text("H.265 (HEVC)").tag(StreamCodec.hevc)
                    }
                    InfoTip(text: "Default for devices without their own override. H.265 carries noticeably more detail for the same bitrate, but needs an updated receiver: Android 1.2+ and Mac receivers from v18 decode it; current iOS, Windows and Linux receivers show a black screen. Safer to leave this on H.264 and enable H.265 per device in each device's settings.")
                }

                HStack {
                    Picker("Frame Rate", selection: $client.selectedFPS) {
                        Text("Auto (60)").tag(0)
                        Text("30 FPS").tag(30)
                        Text("60 FPS").tag(60)
                        Text("120 FPS").tag(120)
                    }
                    InfoTip(text: "Auto picks the best rate per connection (60). 30 saves bandwidth and battery. 120 is experimental for high-refresh receivers; needs a strong link and doubles bandwidth. Hit Apply Settings (or reconnect) to take effect.")
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
                VStack(spacing: 8) {
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
                    }

                    HStack(spacing: 10) {
                        Button("Setup Wizard") {
                            hasCompletedOnboarding = false
                        }

                        Button("Replay Tour") {
                            hasCompletedTour = false
                            selection = .devices
                        }
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
            // About & Changelog
            Section("About") {
                LabeledContent("Version") {
                    Text("BetterCast \(UpdateChecker.currentVersion)")
                        .foregroundStyle(.secondary)
                }

                if updateChecker.checkedOnce {
                    if updateChecker.updateAvailable, let version = updateChecker.latestVersion {
                        HStack {
                            Label("Update available: \(version)", systemImage: "arrow.down.circle.fill")
                                .foregroundColor(.green)
                            Spacer()
                            Button("Download") {
                                if let urlStr = updateChecker.downloadURL, let url = URL(string: urlStr) {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    } else {
                        Label("You're on the latest version", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    }
                }
            }

            Section("What's New") {
                ForEach(Changelog.entries) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(entry.version)
                                .font(.system(size: 14, weight: .bold))
                            Spacer()
                            Text(entry.date)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(entry.highlights, id: \.self) { item in
                            HStack(alignment: .top, spacing: 6) {
                                Text("\u{2022}")
                                    .foregroundStyle(.secondary)
                                Text(item)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .onAppear { updateChecker.checkForUpdates() }
    }

    @ObservedObject private var updateChecker = UpdateChecker.shared

    private func deviceIcon(for service: DiscoveredService) -> String {
        let name = service.name.lowercased()
        if name.contains("android") { return "apps.iphone" }
        if name.contains("windows") { return "pc" }
        if name.contains("linux") { return "desktopcomputer" }
        return "display"
    }

    // MARK: - Getting Started / Overview

    private var hasAnyDevices: Bool {
        !client.foundServices.isEmpty || !client.connectedDisplays.isEmpty
    }

    private var gettingStartedView: some View {
        VStack(spacing: 0) {
            if !client.connectedDisplays.isEmpty {
                // Display arrangement overview
                DisplayOverviewView(client: client, selection: $selection)
            } else if hasAnyDevices {
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

    private func gettingStartedStep(number: Int, title: LocalizedStringKey, subtitle: LocalizedStringKey) -> some View {
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

// MARK: - Display Overview (arrangement view)

/// A display item in the arrangement view — either the built-in display or a BetterCast virtual display.
struct DisplayItem: Identifiable {
    let id: String
    let name: String
    let width: CGFloat   // pixels
    let height: CGFloat  // pixels
    let originX: CGFloat // CG coordinate origin
    let originY: CGFloat
    let isBuiltIn: Bool
    var connectionId: UUID? = nil
    var cgDisplayID: CGDirectDisplayID? = nil
}

/// Captures periodic screenshots for all active displays.
class DisplayThumbnailProvider: ObservableObject {
    @Published var thumbnails: [String: NSImage] = [:] // keyed by DisplayItem.id
    private var timer: Timer?

    func start(displays: [DisplayItem]) {
        capture(displays: displays)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.capture(displays: displays)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func capture(displays: [DisplayItem]) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var newThumbs: [String: NSImage] = [:]

            for display in displays {
                let displayID: CGDirectDisplayID
                if display.isBuiltIn {
                    displayID = CGMainDisplayID()
                    // Try to find actual built-in display
                    var onlineDisplays = [CGDirectDisplayID](repeating: 0, count: 16)
                    var displayCount: UInt32 = 0
                    CGGetOnlineDisplayList(16, &onlineDisplays, &displayCount)
                    let builtIn = onlineDisplays.prefix(Int(displayCount)).first { CGDisplayIsBuiltin($0) != 0 }
                    if let builtIn = builtIn {
                        if let cgImage = CGDisplayCreateImage(builtIn) {
                            newThumbs[display.id] = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                        }
                        continue
                    }
                } else if let did = display.cgDisplayID {
                    displayID = did
                } else {
                    continue
                }

                if let cgImage = CGDisplayCreateImage(displayID) {
                    newThumbs[display.id] = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                }
            }

            DispatchQueue.main.async {
                self?.thumbnails = newThumbs
            }
        }
    }
}

/// macOS System Settings–style display arrangement overview with drag and live previews.
struct DisplayOverviewView: View {
    @ObservedObject var client: NetworkClient
    @Binding var selection: BetterCastSenderApp.SidebarSelection?
    @State private var selectedDisplayId: String? = nil
    @StateObject private var thumbProvider = DisplayThumbnailProvider()

    private var displays: [DisplayItem] {
        var items: [DisplayItem] = []
        let bcCGIDs = Set(client.connectedDisplays.compactMap { $0.cgDisplayID })

        // Built-in display
        if let builtinScreen = NSScreen.builtin ?? NSScreen.main {
            let frame = builtinScreen.frame
            items.append(DisplayItem(
                id: "builtin",
                name: builtinScreen.localizedName,
                width: frame.width,
                height: frame.height,
                originX: frame.origin.x,
                originY: frame.origin.y,
                isBuiltIn: true
            ))
        }

        // Real external displays — physically connected monitors that are NOT the built-in
        // and NOT one of our BetterCast virtual displays. Shown so the arrangement reflects
        // the actual desk setup. They get a live preview via their CGDisplayID.
        for screen in NSScreen.screens {
            guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { continue }
            if CGDisplayIsBuiltin(num) != 0 { continue }   // built-in already added
            if bcCGIDs.contains(num) { continue }          // BetterCast virtual added below
            let frame = screen.frame
            items.append(DisplayItem(
                id: "ext-\(num)",
                name: screen.localizedName,
                width: frame.width,
                height: frame.height,
                originX: frame.origin.x,
                originY: frame.origin.y,
                isBuiltIn: false,
                cgDisplayID: num
            ))
        }

        // Connected BetterCast displays
        for display in client.connectedDisplays {
            let b = display.displayBounds
            let w = b.width > 0 ? b.width : 1920
            let h = b.height > 0 ? b.height : 1080
            items.append(DisplayItem(
                id: display.id.uuidString,
                name: display.name,
                width: w,
                height: h,
                originX: b.origin.x,
                originY: b.origin.y,
                isBuiltIn: false,
                connectionId: display.id,
                cgDisplayID: display.cgDisplayID
            ))
        }

        return items
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Display arrangement area
                DashboardCard {
                    VStack(spacing: 12) {
                        HStack {
                            Text("Displays")
                                .font(.system(size: 14, weight: .semibold))
                            Spacer()
                            Button {
                                openDisplaySettings()
                            } label: {
                                Label("Arrange...", systemImage: "rectangle.3.group")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }

                        displayArrangementView
                            .frame(height: 240)
                            .frame(maxWidth: .infinity)
                    }
                }

                // Selected display info
                if let selected = displays.first(where: { $0.id == selectedDisplayId }) {
                    selectedDisplayCard(selected)
                }

                // Connected devices list
                DashboardCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Connected Devices")
                            .font(.system(size: 14, weight: .semibold))

                        ForEach(client.connectedDisplays) { display in
                            HStack(spacing: 12) {
                                Image(systemName: deviceIcon(for: display.name))
                                    .font(.system(size: 20))
                                    .foregroundStyle(.green)
                                    .frame(width: 28)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(display.name)
                                        .font(.system(size: 13, weight: .medium))
                                    Text(display.resolution)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Button("Settings") {
                                    selection = .device(display.id)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)

                                Button("Disconnect") {
                                    client.disconnectConnection(display.id)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .tint(.red)
                            }
                            .padding(.vertical, 4)

                            if display.id != client.connectedDisplays.last?.id {
                                Divider()
                            }
                        }
                    }
                }

                // Discovered (not yet connected)
                if !client.foundServices.isEmpty {
                    let unconnected = client.foundServices.filter { svc in
                        !client.connectedDisplays.contains(where: { $0.name == svc.name })
                    }
                    if !unconnected.isEmpty {
                        DashboardCard {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Available Devices")
                                    .font(.system(size: 14, weight: .semibold))

                                ForEach(unconnected) { service in
                                    HStack(spacing: 12) {
                                        Image(systemName: "display")
                                            .font(.system(size: 20))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 28)

                                        Text(service.name)
                                            .font(.system(size: 13))

                                        Spacer()

                                        Button("Connect") {
                                            client.connect(to: service)
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.small)
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                        }
                    }
                }

                // Transfer speed
                if !client.connectedDisplays.isEmpty {
                    DashboardCard {
                        HStack {
                            Text("Transfer Speed")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(client.transferRate)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(.green)
                        }
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Devices")
        .onAppear { thumbProvider.start(displays: displays) }
        .onDisappear { thumbProvider.stop() }
        .onChange(of: client.connectedDisplays.count) { _ in
            thumbProvider.start(displays: displays)
        }
    }

    // MARK: - Display Arrangement (draggable + live preview)

    private var displayArrangementView: some View {
        GeometryReader { geo in
            let allDisplays = displays
            let layout = computeLayout(displays: allDisplays, containerSize: geo.size)

            ZStack {
                ForEach(allDisplays) { display in
                    if let info = layout.positions[display.id] {
                        displayThumbnail(display: display, width: info.thumbW, height: info.thumbH)
                            .position(x: info.centerX, y: info.centerY)
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    selectedDisplayId = display.id
                                }
                            }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.5))
            )
        }
    }

    private func displayThumbnail(display: DisplayItem, width: CGFloat, height: CGFloat) -> some View {
        let isSelected = selectedDisplayId == display.id

        return VStack(spacing: 4) {
            ZStack {
                // Live preview or fallback
                if let thumb = thumbProvider.thumbnails[display.id] {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: width, height: height)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                } else {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(display.isBuiltIn
                            ? Color(nsColor: .controlBackgroundColor)
                            : Color.accentColor.opacity(0.1))
                }

                // Border
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.gray.opacity(0.5),
                        lineWidth: isSelected ? 2.5 : 1
                    )
            }
            .frame(width: width, height: height)
            .shadow(color: isSelected ? Color.accentColor.opacity(0.3) : .clear, radius: 4)

            Text(displayLabel(display))
                .font(.system(size: 9))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
                .frame(width: max(width, 60))
        }
    }

    private func displayLabel(_ display: DisplayItem) -> String {
        if display.isBuiltIn { return tr("Built-in Display") }
        let name = display.name
        if name.count > 20 { return String(name.prefix(18)) + "..." }
        return name
    }

    // MARK: - Layout Computation

    private struct LayoutInfo {
        var positions: [String: ThumbPosition] = [:]
        var scale: CGFloat = 1
    }

    private struct ThumbPosition {
        var centerX: CGFloat
        var centerY: CGFloat
        var thumbW: CGFloat
        var thumbH: CGFloat
    }

    /// Compute positions based on actual CG display origins, scaled to fit the container.
    private func computeLayout(displays: [DisplayItem], containerSize: CGSize) -> LayoutInfo {
        guard !displays.isEmpty else { return LayoutInfo() }

        // Find the bounding box of all displays in CG coordinates
        var minX = CGFloat.infinity, minY = CGFloat.infinity
        var maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        for d in displays {
            minX = min(minX, d.originX)
            minY = min(minY, d.originY)
            maxX = max(maxX, d.originX + d.width)
            maxY = max(maxY, d.originY + d.height)
        }
        let totalW = maxX - minX
        let totalH = maxY - minY

        // Scale to fit in container with padding
        let padW = containerSize.width * 0.85
        let padH = containerSize.height * 0.7
        let scale = min(padW / max(totalW, 1), padH / max(totalH, 1), 0.15)

        // Center offset
        let scaledTotalW = totalW * scale
        let scaledTotalH = totalH * scale
        let offsetX = (containerSize.width - scaledTotalW) / 2
        let offsetY = (containerSize.height - scaledTotalH) / 2 - 10

        var info = LayoutInfo(scale: scale)
        for d in displays {
            let thumbW = d.width * scale
            let thumbH = d.height * scale
            let x = (d.originX - minX) * scale + offsetX
            let y = (d.originY - minY) * scale + offsetY
            info.positions[d.id] = ThumbPosition(
                centerX: x + thumbW / 2,
                centerY: y + thumbH / 2,
                thumbW: thumbW,
                thumbH: thumbH
            )
        }
        return info
    }

    private func openDisplaySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Selected Display Card

    private func selectedDisplayCard(_ display: DisplayItem) -> some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display")
                        .font(.system(size: 18))
                        .foregroundColor(display.isBuiltIn ? .secondary : .green)
                    Text(display.isBuiltIn ? "Built-in Display" : display.name)
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                }

                HStack(spacing: 20) {
                    LabeledContent("Resolution") {
                        Text("\(Int(display.width)) x \(Int(display.height))")
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Position") {
                        Text("(\(Int(display.originX)), \(Int(display.originY)))")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 13))

                if !display.isBuiltIn, let connId = display.connectionId {
                    HStack {
                        Button("View Settings") {
                            selection = .device(connId)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private func deviceIcon(for name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("android") { return "apps.iphone" }
        if lower.contains("ipad") || lower.contains("ios") { return "ipad" }
        if lower.contains("windows") { return "pc" }
        if lower.contains("linux") { return "desktopcomputer" }
        return "display"
    }
}

// Helper to find the built-in screen
private extension NSScreen {
    static var builtin: NSScreen? {
        NSScreen.screens.first { screen in
            // Built-in displays have a specific device description key
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                return CGDisplayIsBuiltin(screenNumber) != 0
            }
            return false
        }
    }
}

// MARK: - Unified Device View (connected + discovered)

struct DeviceDetailView: View {
    let display: ConnectedDisplayInfo
    @ObservedObject var client: NetworkClient
    @Binding var selection: BetterCastSenderApp.SidebarSelection?

    private var isAndroidDevice: Bool { display.name.lowercased().contains("android") }
    private var isOnUSB: Bool { display.name.contains("Android (USB)") }
    private var currentTransportLabel: String {
        if display.name.contains("Android (USB)") { return tr("USB (ADB)") }
        if display.name.contains("Android (WiFi ADB)") { return tr("Wireless (WiFi ADB)") }
        return tr("WiFi")
    }

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
                    InfoTip(text: "Renders the virtual display at 2x so text is sharper. Apple receivers report their screen size and stream at their true native resolution; other devices stream at the resolution selected above, downsampled from the 2x framebuffer.")
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
                    Picker("Frame Rate", selection: $client.selectedFPS) {
                        Text("Auto (60)").tag(0)
                        Text("30 FPS").tag(30)
                        Text("60 FPS").tag(60)
                        Text("120 FPS").tag(120)
                    }
                    InfoTip(text: "Auto picks the best rate per connection (60). 30 saves bandwidth and battery. 120 is experimental for high-refresh receivers; needs a strong link and doubles bandwidth. Hit Apply Settings (or reconnect) to take effect.")
                }

                HStack {
                    Toggle("Audio Streaming", isOn: Binding(
                        get: { display.audioEnabled },
                        set: { client.setAudioEnabled($0, for: display.id) }
                    ))
                    InfoTip(text: "Streams system audio to this receiver.")
                }

                HStack {
                    Toggle("Smooth Motion", isOn: Binding(
                        get: { display.smoothMotion },
                        set: { client.setSmoothMotion($0, for: display.id) }
                    ))
                    InfoTip(text: "Lets the encoder spend more bits the moment the picture moves, instead of holding a steady ceiling. Fixes the softness on scene changes and fast motion over Wi-Fi, at the cost of burstier traffic. Takes effect immediately.")
                }

                HStack {
                    Picker(tr("Codec"), selection: Binding(
                        get: { client.codecOverrides[display.name] ?? "auto" },
                        set: { raw in
                            client.setCodecOverride(raw == "auto" ? nil : StreamCodec(rawValue: raw), for: display.name)
                        }
                    )) {
                        Text("\(tr("Default")) (\(client.selectedCodec.displayName))").tag("auto")
                        Text(verbatim: "H.264").tag("h264")
                        Text(verbatim: "H.265 (HEVC)").tag("hevc")
                    }
                    InfoTip(text: "Overrides the app-wide codec for this device only. H.265 looks much better for the same bitrate, but needs an updated receiver — Android 1.2+ and Mac receivers from v18; others show a black screen. Applies immediately; streams blink once while pipelines restart.")
                }
            }

            // Connection transport — switch without disconnecting first (Android only)
            if isAndroidDevice {
                Section("Connection") {
                    LabeledContent("Method") { Text(currentTransportLabel) }
                    if isOnUSB {
                        HStack {
                            Button("Switch to Wireless") {
                                client.switchAndroidToWireless(from: display.id)
                                selection = .devices
                            }
                            InfoTip(text: "Switches to a wireless ADB tunnel so you can unplug the cable. Stays connected through the handoff.")
                        }
                    } else {
                        HStack {
                            Button("Switch to USB (smoother)") {
                                client.switchAndroidToUSB(from: display.id)
                                selection = .devices
                            }
                            InfoTip(text: "Plug in a USB cable first. USB gives lower latency and higher bandwidth than WiFi.")
                        }
                    }
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

    /// The synthetic row for a USB-attached phone; its endpoint is the loopback tunnel.
    private var isUSBSyntheticService: Bool {
        service.name == "Android (USB)"
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

    private var isConnecting: Bool {
        client.connectingUINames.contains(service.name)
    }

    private var connectForm: some View {
        Form {
            if isConnecting {
                Section {
                    ConnectingBanner()
                }
            }
            Section("Connect") {
                if isAndroid {
                    HStack {
                        Image(systemName: "cable.connector")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            HStack(spacing: 6) {
                                Text("ADB (USB)")
                                    .fontWeight(.medium)
                                Text(tr("Recommended"))
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                                    .foregroundStyle(Color.accentColor)
                            }
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
                            Text(client.hasNetworkPath
                                 ? "Fallback — pick the device above instead when it appears"
                                 : tr("Network required — no Wi-Fi connection"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        // Deliberately not prominent. This row used to claim "full quality",
                        // which is not true over Wi-Fi: adb relays every byte through two
                        // daemons on top of the same wireless link the device list already
                        // uses, so it can only ever be slower than connecting directly.
                        Button("Connect") {
                            client.connectADBWireless()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(client.adbInProgress || !client.hasNetworkPath)
                        InfoTip(text: "Wireless ADB tunnel — a fallback for when the device will not connect directly. It carries the stream over the same Wi-Fi as a direct connection but adds an adb relay at each end, so expect lower throughput. Prefer USB, or pick the device from the list above.")
                    }
                    .opacity(client.hasNetworkPath ? 1 : 0.5)

                }

                // The USB row's endpoint is the loopback ADB tunnel, so a "network"
                // connect against it is meaningless — hide it rather than offer a
                // button that dials localhost and pretends to be Wi-Fi.
                if !isUSBSyntheticService {
                    HStack {
                        Image(systemName: "network")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            Text("WiFi (TCP)")
                                .fontWeight(.medium)
                            Text(!client.hasNetworkPath
                                 ? tr("Network required — no Wi-Fi connection")
                                 : (isAndroid ? "30 FPS — direct network, no ADB needed" : "Connect via network"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Connect") {
                            client.connect(to: service)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(!client.hasNetworkPath)
                        InfoTip(text: isAndroid ? "Connects directly over WiFi without ADB. Lower FPS but no USB setup required." : "Connects over your local network. Apple devices use AWDL peer-to-peer when available for best performance.")
                    }
                    .opacity(client.hasNetworkPath ? 1 : 0.5)
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
                    InfoTip(text: "Renders the virtual display at 2x so text is sharper. Apple receivers report their screen size and stream at their true native resolution; other devices stream at the resolution selected above, downsampled from the 2x framebuffer.")
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
                    Picker("Frame Rate", selection: $client.selectedFPS) {
                        Text("Auto (60)").tag(0)
                        Text("30 FPS").tag(30)
                        Text("60 FPS").tag(60)
                        Text("120 FPS").tag(120)
                    }
                    InfoTip(text: "Auto picks the best rate per connection (60). 30 saves bandwidth and battery. 120 is experimental for high-refresh receivers; needs a strong link and doubles bandwidth. Hit Apply Settings (or reconnect) to take effect.")
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

/// Spinner plus a rotating line of copy, shown while a dial is in flight.
///
/// A connection attempt legitimately takes several seconds (the AWDL probe alone is
/// worth five, and an infrastructure retry doubles it), and until now the window showed
/// nothing at all during that wait — a live person staring at a button that looked dead.
/// The copy leans playful on purpose; the spinner is the actual information.
struct ConnectingBanner: View {
    /// tr() keys, cycled in order. First and last are the honest ones; the middle is
    /// flavour, and the sequence parks on "Almost there…" rather than looping forever.
    private static let lines = [
        "Connecting…",
        "Waking up the Wi-Fi radio…",
        "Negotiating codecs…",
        "Tokenmaxxing…",
        "Clauding…",
        "Codexing…",
        "Carving your desktop into packets…",
        "Almost there…",
    ]
    @State private var index = 0
    private let timer = Timer.publish(every: 1.3, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(tr(ConnectingBanner.lines[index]))
                .font(.callout)
                .foregroundStyle(.secondary)
                .id(index)
                .transition(.opacity)
        }
        .onReceive(timer) { _ in
            withAnimation(.easeInOut(duration: 0.25)) {
                index = min(index + 1, ConnectingBanner.lines.count - 1)
            }
        }
    }
}

struct InfoTip: View {
    let text: LocalizedStringKey
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
    /// Loosens the encoder's per-window burst ceiling for this receiver. See
    /// VideoEncoder.burstMultiplier — off by default so no existing connection changes.
    var smoothMotion: Bool = false
    var cgDisplayID: CGDirectDisplayID? = nil
}

struct DiscoveredService: Identifiable {
    let id = UUID()
    let name: String
    let endpoint: NWEndpoint
    /// Whether this service has ever been browsed on an AWDL/link-local interface.
    ///
    /// Only Apple devices answer on awdl0. Forcing a peer-to-peer dial at anything that
    /// has never appeared there costs two five-second timeouts before the infrastructure
    /// fallback — which is what an Android phone used to pay on every single connect.
    /// Sticky, because AWDL is an on-demand radio and may not be up on the first browse.
    var seenOnAWDL: Bool = false
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
        case .low: return tr("Low (5 Mbps)")
        case .medium: return tr("Medium (10 Mbps)")
        case .high: return tr("High (20 Mbps)")
        case .ultra: return tr("Ultra (50 Mbps)")
        case .extreme: return tr("Extreme (100 Mbps)")
        }
    }
}

enum NetworkInterfacePreference: String, CaseIterable, Identifiable {
    case auto = "Auto (Apple Default)"
    case p2pOnly = "Force P2P (WiFi Direct)"
    case routerOnly = "Force Router/WiFi"
    case wiredCable = "USB / Thunderbolt Cable"

    var id: String { self.rawValue }

    /// Localized label for the UI. `rawValue` is persisted in UserDefaults and
    /// must stay stable, so translation happens here with the raw value as key.
    var displayName: String { tr(self.rawValue) }
}

// Per-connection pipeline: each device gets its own virtual display, screen capture, and encoder
struct ConnectionPipeline {
    let id: UUID
    let connection: NWConnection
    // var, not let: an invite pipeline is created before the device tells us its
    // name, so handleDeviceHello renames it in place rather than reconnecting.
    var service: DiscoveredService
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
    // TCP backpressure: how many sends are still in flight.
    //
    // This was a Bool, and any frame arriving while one send was outstanding got dropped.
    // Dropping a P-frame breaks the decoder's reference chain, so the picture pixelates
    // until the next keyframe — measured at 1-11 drops per second during motion, which is
    // continuous visible corruption. SideScreen never drops (its log reads "dropped: 0"
    // throughout) and simply lets a couple of frames queue.
    //
    // Our own frame age sits at 6-11ms against their 8-13ms, so we were destroying picture
    // quality to defend a latency budget we were nowhere near spending. Allow a shallow
    // queue and only drop once it is genuinely backing up.
    var pendingSends: Int = 0
    var sendInProgress: Bool = false
    // Time-based send pacing for WiFi ADB (prevents kernel buffer bloat)
    var lastSendTimeNs: UInt64 = 0
    // WiFi ADB vs USB ADB — WiFi has much less bandwidth, needs throttling
    var isWiFiADB: Bool = false
    // ADB/localhost connections always use TCP framing regardless of global protocol setting
    var forceTCP: Bool = false
    // Adaptive bitrate state lives on the VideoEncoder (a class), not here — see VideoEncoder.
    // iOS/Mac Swift receivers don't strip the type byte — send raw payloads for them
    var supportsTypeByte: Bool = true
    // Receiver-reported screen dimensions (pixels) — used to match aspect ratio
    var reportedScreenWidth: Int? = nil
    var reportedScreenHeight: Int? = nil
}

class NetworkClient: ObservableObject, VideoEncoderDelegate, AudioEncoderDelegate {
    private var browser: NWBrowser?
    private var pipelines: [UUID: ConnectionPipeline] = [:]

    @Published var status: String = "Idle"
    @Published var foundServices: [DiscoveredService] = []
    @Published var connectedServices: [DiscoveredService] = []
    private var connectingServiceNames: Set<String> = [] // Prevent double-connect race

    /// UI mirror of `connectingServiceNames`. The private set exists to stop
    /// double-connect races and is touched from connection callbacks; this one is only
    /// ever mutated on the main queue so SwiftUI can watch it. Before it existed the app
    /// knew it was connecting but the window showed nothing, and a dial that legitimately
    /// takes several seconds (the AWDL probe, an infrastructure retry) looked like a dead
    /// button.
    @Published var connectingUINames: Set<String> = []

    private func markConnecting(_ name: String) {
        connectingServiceNames.insert(name)
        DispatchQueue.main.async { self.connectingUINames.insert(name) }
    }
    private func unmarkConnecting(_ name: String) {
        connectingServiceNames.remove(name)
        DispatchQueue.main.async { self.connectingUINames.remove(name) }
    }

    /// True when `serviceName` is connected directly OR via its " P2P" sibling.
    /// Apple devices advertise both `<name>` (Wi-Fi listener) and `<name> P2P`
    /// (AWDL listener); when the device-hello redial lands on the P2P variant,
    /// the sidebar row for the base name should still reflect "Connected".
    func isConnectedConsideringP2P(serviceName: String) -> Bool {
        let base = serviceName.hasSuffix(" P2P") ? String(serviceName.dropLast(4)) : serviceName
        let p2p = "\(base) P2P"
        return connectedServices.contains { $0.name == serviceName || $0.name == base || $0.name == p2p }
    }
    @Published var useVirtualDisplay: Bool = NetworkClient.loadBool(SettingsKey.useVirtualDisplay, default: true) { // mirroring vs extended display
        didSet { UserDefaults.standard.set(useVirtualDisplay, forKey: SettingsKey.useVirtualDisplay) }
    }
    /// Compatibility capture mode: uses CGDisplayStream to read the GPU's composited
    /// framebuffer directly, bypassing ScreenCaptureKit's DRM/HDCP blocking.
    /// Enable this to capture DRM-protected content (Netflix, Apple TV, etc.).
    /// Trade-off: slightly higher CPU usage, no virtual display support.
    @Published var useLegacyCapture: Bool = NetworkClient.loadBool(SettingsKey.legacyCapture, default: false) {
        didSet { UserDefaults.standard.set(useLegacyCapture, forKey: SettingsKey.legacyCapture) }
    }
    @Published var audioStreamingEnabled: Bool = NetworkClient.loadBool(SettingsKey.audio, default: true) { // Master toggle for audio streaming
        didSet { UserDefaults.standard.set(audioStreamingEnabled, forKey: SettingsKey.audio) }
    }
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
    /// The one stats/adaptive timer. Held so a second connection cannot start another —
    /// startStatsTimer() is called per connection, and every extra timer was another
    /// adaptBitrates() pass per second, splitting the drop counters into tiny samples and
    /// letting the bitrate move several steps a second.
    private var statsTimer: Timer?
    private var lastStatsTime: Date = Date()
    
    // MARK: - Persisted settings (remembered between launches — issue #32)
    // Backed by UserDefaults: loaded as each property's default, saved in didSet.
    private enum SettingsKey {
        static let quality = "setting.quality"
        static let resWidth = "setting.resWidth"
        static let resHeight = "setting.resHeight"
        static let retina = "setting.retina"
        static let connectionType = "setting.connectionType"
        static let audio = "setting.audioStreaming"
        static let interfacePref = "setting.interfacePreference"
        static let autoConnect = "setting.autoConnect"
        static let useVirtualDisplay = "setting.useVirtualDisplay"
        static let manualHost = "setting.manualHost"
        static let manualPort = "setting.manualPort"
        static let fps = "setting.fps"
        static let legacyCapture = "setting.legacyCapture"
    }
    private static func loadQuality() -> StreamQuality {
        (UserDefaults.standard.object(forKey: SettingsKey.quality) as? Int)
            .flatMap(StreamQuality.init(rawValue:)) ?? .high
    }
    private static func loadResolution() -> VirtualDisplayManager.Resolution {
        let d = UserDefaults.standard
        if let w = d.object(forKey: SettingsKey.resWidth) as? Int,
           let h = d.object(forKey: SettingsKey.resHeight) as? Int,
           let match = VirtualDisplayManager.defaultResolutions.first(where: { $0.width == w && $0.height == h }) {
            return match
        }
        return VirtualDisplayManager.defaultResolutions[1]
    }
    private static func loadInterfacePreference() -> NetworkInterfacePreference {
        (UserDefaults.standard.string(forKey: SettingsKey.interfacePref))
            .flatMap(NetworkInterfacePreference.init(rawValue:)) ?? .auto
    }
    /// Reads a persisted Bool, falling back to `default` when the key was never set.
    private static func loadBool(_ key: String, default fallback: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil ? fallback : UserDefaults.standard.bool(forKey: key)
    }

    // Settings
    @Published var selectedResolution: VirtualDisplayManager.Resolution = NetworkClient.loadResolution() {
        didSet {
            UserDefaults.standard.set(selectedResolution.width, forKey: SettingsKey.resWidth)
            UserDefaults.standard.set(selectedResolution.height, forKey: SettingsKey.resHeight)
        }
    }
    @Published var isRetina: Bool = NetworkClient.loadBool(SettingsKey.retina, default: false) {
        didSet { UserDefaults.standard.set(isRetina, forKey: SettingsKey.retina) }
    }
    @Published var connectionType: String = (UserDefaults.standard.string(forKey: SettingsKey.connectionType) ?? "TCP") {
        didSet {
            UserDefaults.standard.set(connectionType, forKey: SettingsKey.connectionType)
            // Restart browsing if type changes
            browser?.cancel()
            startBrowsing()
        }
    }

    /// Codec for new pipelines. Reconnect to apply — the session is built at pipeline start.
    @Published var selectedCodec: StreamCodec =
        StreamCodec(rawValue: UserDefaults.standard.string(forKey: "streamCodec") ?? "") ?? .h264 {
        didSet { UserDefaults.standard.set(selectedCodec.rawValue, forKey: "streamCodec") }
    }

    /// Per-device codec overrides, keyed by service name. Absent = follow the global
    /// picker. Exists because the global setting is a foot-gun: only the updated Android
    /// receiver decodes H.265 today, and a global switch silently blanked the iPhone and
    /// Mac receivers — the sender streams happily while the receiver discards everything.
    @Published var codecOverrides: [String: String] =
        UserDefaults.standard.dictionary(forKey: "codecOverrides") as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(codecOverrides, forKey: "codecOverrides") }
    }

    func codecFor(serviceName: String) -> StreamCodec {
        if let raw = codecOverrides[serviceName], let c = StreamCodec(rawValue: raw) { return c }
        return selectedCodec
    }

    /// nil clears the override (follow the global default). Applies live through the
    /// same seamless pipeline restart the settings Apply uses.
    func setCodecOverride(_ codec: StreamCodec?, for serviceName: String) {
        if let codec { codecOverrides[serviceName] = codec.rawValue }
        else { codecOverrides.removeValue(forKey: serviceName) }
        LogManager.shared.log("Sender: Codec for \(serviceName): \(codec?.displayName ?? "default (\(selectedCodec.displayName))")")
        updateStreamResolution()
    }

    @Published var selectedQuality: StreamQuality = NetworkClient.loadQuality() {
        didSet { UserDefaults.standard.set(selectedQuality.rawValue, forKey: SettingsKey.quality) }
    }

    /// User frame-rate override: 0 = Auto (per-path default, 60), or 30 / 60 / 120.
    /// 120 also creates the virtual display at 120Hz for receivers with high-refresh panels.
    @Published var selectedFPS: Int = (UserDefaults.standard.object(forKey: SettingsKey.fps) as? Int) ?? 0 {
        didSet { UserDefaults.standard.set(selectedFPS, forKey: SettingsKey.fps) }
    }

    // Manual Interface Toggle — default Auto so Windows/Linux/Android receivers work out of the box
    @Published var interfacePreference: NetworkInterfacePreference = NetworkClient.loadInterfacePreference() {
        didSet { UserDefaults.standard.set(interfacePreference.rawValue, forKey: SettingsKey.interfacePref) }
    }

    // Auto-connect: automatically connect to discovered receivers
    @Published var autoConnect: Bool = NetworkClient.loadBool(SettingsKey.autoConnect, default: false) {
        didSet { UserDefaults.standard.set(autoConnect, forKey: SettingsKey.autoConnect) }
    }

    // Manual connection
    @Published var manualHost: String = (UserDefaults.standard.string(forKey: SettingsKey.manualHost) ?? "") {
        didSet { UserDefaults.standard.set(manualHost, forKey: SettingsKey.manualHost) }
    }
    @Published var manualPort: String = (UserDefaults.standard.string(forKey: SettingsKey.manualPort) ?? "51820") {
        didSet { UserDefaults.standard.set(manualPort, forKey: SettingsKey.manualPort) }
    }

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

                // Harvest the AWDL interface from browse results. NWPathMonitor never
                // reports awdl0 in availableInterfaces (it only appears on a satisfied
                // path, which needs a P2P connection to already exist), so the monitor
                // in init() leaves cachedAWDLInterface nil forever. Without a real
                // interface reference the P2P paths can only ban infrastructure and
                // hope AWDL comes up on its own — which is the connect-timeout loop.
                if self.cachedAWDLInterface == nil,
                   let awdl = results.lazy.flatMap({ $0.interfaces })
                       .first(where: { $0.name.contains("awdl") || $0.name.contains("llw") }) {
                    self.cachedAWDLInterface = awdl
                    LogManager.shared.log("Sender: Cached P2P interface \(awdl.name) from browse results ✅")
                }

                // Log which interfaces each newly-seen service is reachable on — the
                // difference between "found on awdl0 + en0" and "found on en0 only"
                // decides whether a forced-P2P dial can ever succeed.
                for change in changes {
                    if case .added(let result) = change,
                       case .service(let name, _, _, _) = result.endpoint {
                        let ifaces = result.interfaces.map { $0.name }.joined(separator: ", ")
                        LogManager.shared.log("Sender: Discovered '\(name)' on [\(ifaces.isEmpty ? "none" : ifaces)]")
                    }
                }

                // Build list from mDNS browse results
                var services = results.compactMap { result -> DiscoveredService? in
                    if case .service(let name, _, _, _) = result.endpoint {
                        let onAWDL = result.interfaces.contains {
                            $0.name.contains("awdl") || $0.name.contains("llw")
                        }
                        // Sticky: once seen on AWDL, stay seen. The radio sleeps.
                        let previously = self.foundServices.first(where: { $0.name == name })?.seenOnAWDL ?? false
                        return DiscoveredService(name: name, endpoint: result.endpoint,
                                                 seenOnAWDL: onAWDL || previously)
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

                // Drop dismissals for records that have genuinely gone away, so a
                // device that really comes back reappears instead of staying hidden.
                let liveNames = Set(services.map { $0.name })
                self.dismissedServiceNames.formIntersection(liveNames)

                self.foundServices = services.filter { !self.dismissedServiceNames.contains($0.name) }

                // Auto-connect to newly discovered services
                if self.autoConnect {
                    for service in services {
                        if !self.connectedServices.contains(where: { $0.name == service.name })
                            && !self.connectingServiceNames.contains(service.name) {
                            // Skip ADB synthetic entries
                            if service.name.contains("Android (USB)") || service.name.contains("Android (WiFi ADB)") { continue }
                            // Skip " P2P" duplicate — sender uses P2P automatically for Apple devices
                            if service.name.hasSuffix(" P2P") && services.contains(where: { $0.name == String(service.name.dropLast(4)) }) { continue }
                            LogManager.shared.log("Sender: Auto-connecting to \(service.name)")
                            self.connect(to: service)
                        }
                    }
                }
            }
        }

        browser.start(queue: .main)

        // Discovery alone misses a USB-attached phone when Wi-Fi is off.
        startADBUSBWatch()
    }

    /// Listen for iOS receivers that want to dial THIS Mac and ask it to start streaming.
    /// Counterpart to startBrowsing(): instead of the Mac finding receivers, receivers find
    /// the Mac via Bonjour (`_bettercast-sender._tcp`) and open a TCP connection to this
    /// listener. Once the connection is ready, we wrap it in a ConnectionPipeline and run
    /// the standard pipeline flow exactly as if the Mac had dialed out.
    func startSenderInviteListener() {
        guard senderInviteListener == nil else { return }
        do {
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.enableKeepalive = true
            tcpOptions.noDelay = true
            let parameters = NWParameters(tls: nil, tcp: tcpOptions)
            parameters.includePeerToPeer = true
            parameters.allowLocalEndpointReuse = true
            parameters.serviceClass = .interactiveVideo

            let port = NWEndpoint.Port(integerLiteral: BCConstants.senderInvitePort)
            let listener = try NWListener(using: parameters, on: port)

            let macName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
            listener.service = NWListener.Service(name: macName, type: BCConstants.senderInviteServiceType)

            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    LogManager.shared.log("Sender: Invite listener ready on port \(BCConstants.senderInvitePort), advertising \(BCConstants.senderInviteServiceType)")
                case .failed(let error):
                    LogManager.shared.log("Sender: Invite listener failed: \(error)")
                default: break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                LogManager.shared.log("Sender: Invite — incoming connection from \(connection.endpoint)")
                self?.handleIncomingInvite(connection: connection)
            }

            listener.start(queue: .main)
            self.senderInviteListener = listener
        } catch {
            LogManager.shared.log("Sender: Invite listener failed to start on port \(BCConstants.senderInvitePort): \(error)")
        }
    }

    /// Wrap an iOS-dialed incoming socket as a regular ConnectionPipeline.
    /// Mirrors the .ready branch of connect(to:) — the data direction (Mac → iOS) is the same;
    /// only the call direction is reversed.
    private func handleIncomingInvite(connection: NWConnection) {
        let connectionId = UUID()

        connection.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch state {
                case .ready:
                    // Detect link type
                    var isP2P = false
                    var isLoopback = false
                    if let path = connection.currentPath {
                        let interfaces = path.availableInterfaces.map { $0.debugDescription }.joined(separator: ", ")
                        LogManager.shared.log("Sender: Invite path: \(path)")
                        if interfaces.contains("awdl") {
                            isP2P = true
                            LogManager.shared.log("Sender: Invite — P2P/AWDL ✅")
                        } else if interfaces.contains("lo0") || interfaces.contains("loopback") {
                            isLoopback = true
                        }
                    }

                    // Synthesize a service name from the remote endpoint so the rest of the
                    // sender code (UI, pipeline routing, logs) can treat this like a normal device.
                    let serviceName: String
                    switch connection.endpoint {
                    case .hostPort(let host, let port):
                        serviceName = "iOS @ \(host):\(port)"
                    default:
                        serviceName = "iOS (invited)"
                    }
                    let service = DiscoveredService(name: serviceName, endpoint: connection.endpoint)

                    var pipeline = ConnectionPipeline(
                        id: connectionId,
                        connection: connection,
                        service: service,
                        lastHeartbeat: Date()
                    )
                    pipeline.isP2P = isP2P
                    pipeline.isLoopback = isLoopback
                    // Invite-initiated connections always come from a modern iOS receiver
                    // (NetworkListenerIOS), which auto-detects type-byte framing on the first
                    // received frame. Keeping this true is required for audio to flow — the
                    // audioEncoder delegate skips sending when supportsTypeByte is false.
                    pipeline.supportsTypeByte = true

                    self.pipelines[connectionId] = pipeline
                    self.connectedServices.append(service)
                    self.updateConnectedDisplays()

                    let count = self.pipelines.count
                    self.status = "Connected to \(count) device(s)"
                    LogManager.shared.log("Sender: Invite — connected to \(serviceName) (Total: \(count), P2P: \(isP2P))")

                    self.startPipeline(for: connectionId)

                    if count == 1 {
                        self.startHeartbeatMonitor()
                        self.startStatsTimer()
                    }

                    self.receive(on: connection, connectionId: connectionId)

                case .failed(let error):
                    LogManager.shared.log("Sender: Invite connection failed: \(error)")
                    connection.cancel()
                    connection.stateUpdateHandler = nil // Release even if failed before .ready
                    self.removeConnection(connectionId)
                case .cancelled:
                    self.removeConnection(connectionId)
                    connection.stateUpdateHandler = nil // Break self-retain cycle
                default: break
                }
            }
        }

        connection.start(queue: .main)
    }

    // Heartbeat
    private var lastHeartbeatTime: Date = Date()
    private var heartbeatTimer: Timer?
    private var connectionRefusedCount: Int = 0

    // Hard-Lock AWDL Logic
    /// Whether a real (non-loopback) network path exists.
    ///
    /// Drives the UI so network-based connect options are only offered when they
    /// could actually work. With Wi-Fi off the ADB USB tunnel still streams fine
    /// over loopback, so the app must not imply the Wi-Fi routes are available.
    @Published var hasNetworkPath: Bool = true

    private let interfaceMonitor = NWPathMonitor()
    private var cachedAWDLInterface: NWInterface?
    private var cachedInfraInterface: NWInterface?

    // iOS-initiated connections: this sender listens on senderInvitePort and advertises
    // _bettercast-sender._tcp so iOS receivers can discover the sender and dial it.
    private var senderInviteListener: NWListener?
    
    init() {
        LogManager.shared.log("Sender: App Starting")
        
        // We can't monitor recursively in init easily, but we can start it.
        interfaceMonitor.pathUpdateHandler = { [weak self] path in
            // Loopback alone is not a network — the ADB tunnel rides it with Wi-Fi off.
            let usable = path.status == .satisfied
                && path.availableInterfaces.contains { $0.type != .loopback }
            DispatchQueue.main.async {
                guard let self = self else { return }
                if self.hasNetworkPath != usable {
                    self.hasNetworkPath = usable
                    LogManager.shared.log(usable
                        ? "Network: Network path available"
                        : "Network: No network path — Wi-Fi connect options disabled (USB still works)")
                }
            }

            for interface in path.availableInterfaces {
                // Cache AWDL
                if interface.name.contains("awdl") || interface.name.contains("llw") {
                    let isNew = (self?.cachedAWDLInterface == nil)
                    self?.cachedAWDLInterface = interface
                    
                    if isNew {
                         LogManager.shared.log("Network: Found P2P Interface: \(interface.name) (\(interface.type))")
                         // Restart browsing on this interface so we get the Link-Local Address
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
        
        // Use cached AWDL if available (especially for Browser)
        if interfacePreference == .p2pOnly, let awdl = cachedAWDLInterface {
             LogManager.shared.log("Parameters: Binding to P2P Interface \(awdl.name) ✅")
             parameters.requiredInterface = awdl
             parameters.serviceClass = .interactiveVideo
             parameters.prohibitedInterfaceTypes = [.loopback, .wiredEthernet]
             return // Skip the rest
        }
        
        switch interfacePreference {
        case .auto:
            // Deliberately no requiredInterfaceType. AWDL is an on-demand radio:
            // the system only powers awdl0 up while something is actively running a
            // peer-to-peer browse or listen. Pinning this to .wifi restricted the
            // browse to the infrastructure interface and undercut the
            // includePeerToPeer above, so BetterCast never triggered AWDL activation
            // itself — it only ever worked when AirDrop (or similar) happened to have
            // woken the radio, and broke again the moment that window closed.
            parameters.serviceClass = .responsiveData
            parameters.prohibitedInterfaceTypes = []

        case .p2pOnly:
             // Direct binding to AWDL interface
             if let awdl = cachedAWDLInterface {
                 LogManager.shared.log("Sender: Hard-Locking to Interface: \(awdl.name) ✅")
                 parameters.requiredInterface = awdl
                 // Since we require a specific interface, prohibited list is irrelevant/redundant
             } else {
                 LogManager.shared.log("Sender: AWDL Interface not found yet. Falling back to Prohibition Strategy (Banning Infra). ⚠️")
                 
                 // Ban the interface object directly, NOT the type
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
        markConnecting(service.name)

        let deviceCount = pipelines.count + 1
        self.status = "Connecting to \(service.name) (Device #\(deviceCount))..."

        // Smart routing: Apple receivers (iOS/Mac) get P2P/AWDL, others get infrastructure
        let nameLower = service.name.lowercased()
        // Manual IP connections (e.g. "10.0.0.5:51820") are never Apple receivers
        let isManualIP = service.name.contains(":") && service.name.first?.isNumber == true
        let nameLooksApple = !isManualIP && !nameLower.contains("android") && !nameLower.contains("windows") && !nameLower.contains("linux")

        // Names are a terrible platform signal: an Android phone advertises
        // "MANUFACTURER MODEL", so a Lenovo Legion Y70 contains none of the words above
        // and used to be dialled as an Apple device — forcing AWDL, timing out twice,
        // and only reaching the phone twelve seconds later over infrastructure.
        //
        // Reachability is the honest signal. Only Apple devices answer on awdl0, so a
        // peer-to-peer dial is worth attempting when the service has actually been seen
        // there, or when it advertises a separate " P2P" instance. Anything else goes
        // straight to infrastructure.
        let hasP2PEndpoint = foundServices.contains { $0.name == service.name + " P2P" }
        let awdlReachable = foundServices.first(where: { $0.name == service.name })?.seenOnAWDL ?? false
        let isAppleReceiver = nameLooksApple && (hasP2PEndpoint || awdlReachable)
        if nameLooksApple && !isAppleReceiver {
            LogManager.shared.log("Sender: \(service.name) never seen on AWDL — dialling infrastructure directly")
        }

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

        // For Apple devices, prefer the P2P endpoint if available (AWDL low-latency)
        var connectEndpoint = service.endpoint
        if interfacePreference == .wiredCable || interfacePreference == .routerOnly {
            // Explicit Mode choice: honor it for the CONNECTION, not just discovery.
            // The Apple smart-routing below forces AWDL and even prohibits
            // .wiredEthernet, so without this branch "USB / Thunderbolt Cable" mode
            // could never actually carry the stream to a Mac receiver (issue #40).
            configureParameters(parameters)
            LogManager.shared.log("Sender: Mode \(interfacePreference.rawValue) — applying to connection for \(service.name)")
        } else if isAppleReceiver {
            if let p2pService = foundServices.first(where: { $0.name == service.name + " P2P" }) {
                // Use the P2P-advertised endpoint for AWDL connection
                connectEndpoint = p2pService.endpoint
                parameters.includePeerToPeer = true
                if let awdl = cachedAWDLInterface {
                    parameters.requiredInterface = awdl
                    LogManager.shared.log("Sender: Apple receiver — using P2P endpoint + AWDL (\(awdl.name)) for \(service.name)")
                } else {
                    if let infra = cachedInfraInterface {
                        LogManager.shared.log("Sender: Apple receiver — using P2P endpoint, banning infra for \(service.name)")
                        parameters.prohibitedInterfaces = [infra]
                    }
                    parameters.prohibitedInterfaceTypes = [.loopback, .wiredEthernet]
                    parameters.serviceClass = .interactiveVideo
                }
            } else {
                // No separate P2P endpoint — force AWDL by banning infrastructure.
                // The 5-second timeout will fall back to infra if AWDL can't be established.
                parameters.includePeerToPeer = true
                parameters.serviceClass = .interactiveVideo
                if let awdl = cachedAWDLInterface {
                    parameters.requiredInterface = awdl
                    LogManager.shared.log("Sender: Apple receiver — requiring AWDL (\(awdl.name)) for \(service.name)")
                } else if let infra = cachedInfraInterface {
                    parameters.prohibitedInterfaces = [infra]
                    parameters.prohibitedInterfaceTypes = [.loopback, .wiredEthernet]
                    LogManager.shared.log("Sender: Apple receiver — banning infra, forcing P2P for \(service.name)")
                } else {
                    LogManager.shared.log("Sender: Apple receiver — enabling P2P discovery for \(service.name)")
                }
            }
        } else {
            // Non-Apple devices: skip P2P, go straight to infrastructure
            parameters.includePeerToPeer = false
            parameters.serviceClass = .interactiveVideo
            LogManager.shared.log("Sender: Non-Apple receiver — using infrastructure for \(service.name)")
        }

        let connection = NWConnection(to: connectEndpoint, using: parameters)
        let connectionId = UUID()

        // Timeout: if connection is still not ready after 5s, retry without P2P
        // This handles cases where AWDL negotiation hangs
        var connectionTimedOut = false
        let timeoutWork = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            // Only retry if still not connected (no pipeline created yet)
            if self.pipelines[connectionId] == nil && !connectionTimedOut {
                connectionTimedOut = true
                self.unmarkConnecting(service.name)
                LogManager.shared.log("Sender: Connection to \(service.name) timed out — retrying via infrastructure")
                connection.cancel()

                // Retry with plain TCP (no interface restrictions)
                let tcpOptions = NWProtocolTCP.Options()
                tcpOptions.enableKeepalive = true
                tcpOptions.noDelay = true
                tcpOptions.connectionTimeout = 10
                let fallbackParams = NWParameters(tls: nil, tcp: tcpOptions)
                fallbackParams.serviceClass = .interactiveVideo
                if self.interfacePreference == .wiredCable {
                    // Cable-only means cable-only: keep the retry on the wired link
                    // instead of silently landing on WiFi, which would look exactly
                    // like the "stuck in wifi mode" confusion from issue #40.
                    self.configureParameters(fallbackParams)
                    LogManager.shared.log("Sender: Cable mode — retrying over wired link only (no WiFi fallback)")
                }
                self.connectWithParameters(service: service, parameters: fallbackParams, forceTCP: false)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeoutWork)

        connection.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    timeoutWork.cancel() // Connection succeeded, cancel timeout
                    self?.unmarkConnecting(service.name)

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
                    // Wireless ADB looks identical to USB ADB from the socket's point of
                    // view (both land on lo0), but only USB has the headroom that flag
                    // implies. Classify it here too, not just on the discovery path, or
                    // flow control depends on which code path opened the connection.
                    pipeline.isWiFiADB = isLoopback && service.name.contains("WiFi")
                    // iOS/Mac Swift receivers don't handle the type byte in TCP framing
                    // Match Mac/iOS Swift receivers that don't handle the type byte.
                    // Bonjour appends " (2)", " (3)" etc. for duplicate names, so we can't use exact match.
                    // Android/Windows/Linux receivers contain their platform keyword and DO support typeByte.
                    let nameLower = service.name.lowercased()
                    let isLegacyReceiver = nameLower.hasPrefix("bettercast receiver")
                        && !nameLower.contains("android") && !nameLower.contains("windows") && !nameLower.contains("linux")
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
                    self?.unmarkConnecting(service.name)
                    LogManager.shared.log("Sender: Connection to \(service.name) failed: \(error)")
                    // Release the connection even if it failed before .ready (no pipeline),
                    // breaking the NWConnection self-retain cycle.
                    connection.cancel()
                    connection.stateUpdateHandler = nil
                    self?.removeConnection(connectionId)

                    let remaining = self?.pipelines.count ?? 0
                    if remaining == 0 {
                        self?.status = "All connections failed"
                    } else {
                        self?.status = "Connected to \(remaining) device(s)"
                    }
                case .cancelled:
                    timeoutWork.cancel()
                    self?.unmarkConnecting(service.name)
                    self?.removeConnection(connectionId)
                    connection.stateUpdateHandler = nil
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
        guard let portNum = UInt16(manualPort), portNum > 0,
              let port = NWEndpoint.Port(rawValue: portNum) else {
            LogManager.shared.log("Sender: Invalid port '\(manualPort)'")
            return
        }

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: port
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
    private var adbPollTimer: Timer?

    /// Run an ADB shell command and return trimmed stdout
    private func runAdb(_ args: [String]) -> (output: String, success: Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/adb")
        process.arguments = args
        // adb's default Openscreen mDNS backend finds nothing on macOS — verified
        // side by side: `dns-sd` and the Bonjour backend both list the pairing
        // service while Openscreen returns an empty list. Without this, wireless
        // pairing can never discover the phone.
        var env = ProcessInfo.processInfo.environment
        env["ADB_MDNS_BACKEND"] = "bonjour"
        process.environment = env
        let pipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errPipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let stdout = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let stderr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let success = process.terminationStatus == 0
            // Surface stderr when the command failed (or stdout was empty) — adb writes
            // errors like "no devices/emulators found" / "cannot bind listener" to stderr.
            let output = (!success || stdout.isEmpty) && !stderr.isEmpty ? stderr : stdout
            return (output, success)
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
    // MARK: - Joining a phone's hotspot

    @Published var showHotspotScanner: Bool = false
    @Published var hotspotSSID: String = ""
    @Published var hotspotPassword: String = ""
    @Published var hotspotJoinStatus: String = ""
    @Published var hotspotJoining: Bool = false

    /// Join the local-only hotspot hosted by the phone.
    ///
    /// This is the no-network path: macOS cannot host a hotspot (Internet Sharing has
    /// no public API), so the phone hosts and the Mac joins. `networksetup` needs no
    /// admin rights for this. Expect the Mac to lose internet — a local-only hotspot
    /// has no upstream, and the Mac has one Wi-Fi radio.
    func joinHotspot() {
        let ssid = hotspotSSID.trimmingCharacters(in: .whitespaces)
        let password = hotspotPassword.trimmingCharacters(in: .whitespaces)
        guard !ssid.isEmpty else {
            hotspotJoinStatus = tr("Enter the network name shown on your phone")
            return
        }
        hotspotJoining = true
        hotspotJoinStatus = tr("Joining…")
        LogManager.shared.log("Hotspot: Joining '\(ssid)'")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
            var args = ["-setairportnetwork", "en0", ssid]
            if !password.isEmpty { args.append(password) }
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            var output = ""
            do {
                try process.run()
                process.waitUntilExit()
                output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            } catch {
                output = "\(error)"
            }

            // networksetup exits 0 even on failure, and reports the problem on stdout.
            let failed = output.lowercased().contains("could not find")
                || output.lowercased().contains("failed")
                || output.lowercased().contains("error")

            DispatchQueue.main.async {
                self.hotspotJoining = false
                if failed {
                    self.hotspotJoinStatus = output.isEmpty ? tr("Could not join that network") : output
                    LogManager.shared.log("Hotspot: Join failed — \(output)")
                } else {
                    self.hotspotJoinStatus = tr("Joined. Connecting to the phone…")
                    LogManager.shared.log("Hotspot: Joined '\(ssid)' ✅")
                    self.hotspotPassword = ""
                    // The interface just changed; re-browse in case mDNS does work.
                    self.startBrowsing()
                    // But don't rely on it — see connectToGateway().
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                        self.connectToGateway()
                    }
                }
            }
        }
    }

    /// The default gateway, which on a phone hotspot is the phone itself.
    private func defaultGateway() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/route")
        process.arguments = ["-n", "get", "default"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch { return nil }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for line in out.components(separatedBy: "\n") where line.contains("gateway:") {
            return line.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// Connect straight to the default gateway on the receiver port.
    ///
    /// Discovery cannot be trusted on a phone hotspot: Android's NsdManager
    /// advertises on the Wi-Fi client interface, and in hotspot mode Wi-Fi is off
    /// and the phone is a soft AP instead, so it never announces itself. The phone
    /// is still listening, and as the AP it is by definition our gateway — so its
    /// address is knowable without any discovery at all.
    func connectToGateway() {
        guard let gateway = defaultGateway() else {
            hotspotJoinStatus = tr("Joined, but no gateway found. Try Manual IP.")
            LogManager.shared.log("Hotspot: No default gateway to connect to")
            return
        }
        // Already connected to it? Leave it alone.
        let name = "\(gateway):\(BCConstants.tcpPort)"
        if connectedServices.contains(where: { $0.name == name }) {
            hotspotJoinStatus = tr("Already connected")
            return
        }
        LogManager.shared.log("Hotspot: Connecting to gateway \(name) (bypassing discovery)")
        hotspotJoinStatus = tr("Connecting to \(gateway)…")
        manualHost = gateway
        manualPort = String(BCConstants.tcpPort)
        connectManual()
    }

    // MARK: - Wireless pairing via QR

    /// Payload for the on-screen QR, non-nil while the pairing sheet is up.
    @Published var qrPairingPayload: String?
    @Published var qrPairingStatus: String = ""
    @Published var qrPairingFailed: Bool = false

    private var qrPairingCode: String?
    private var qrPairingTimer: Timer?
    private var qrPairingDeadline: Date?

    /// Pair with a phone over Wi-Fi by showing a QR its own OS can scan.
    ///
    /// Android 11+ reads `WIFI:T:ADB;S:<name>;P:<code>;;` from Developer options →
    /// Wireless debugging → Pair device with QR code. It then advertises
    /// `_adb-tls-pairing._tcp`, which we find via adb's own mDNS daemon, pair
    /// against, and finally `adb connect` to. No cable at any point, and nothing
    /// to install on the phone — the system scanner does the work.
    func startQRPairing() {
        guard !adbInProgress else { return }
        let name = "BetterCast-\(String(format: "%04d", Int.random(in: 0...9999)))"
        let code = String(format: "%06d", Int.random(in: 0...999999))
        qrPairingCode = code
        qrPairingPayload = "WIFI:T:ADB;S:\(name);P:\(code);;"
        qrPairingFailed = false
        qrPairingStatus = tr("Waiting for you to scan…")
        qrPairingDeadline = Date().addingTimeInterval(180)
        LogManager.shared.log("ADB QR: Waiting for pairing service (name \(name))")

        // The running adb server keeps whichever backend it was started with, so a
        // server launched before this fix would still be blind. Restart it — but not
        // while a stream is live, since that would drop an active USB tunnel.
        if connectedDisplays.isEmpty {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                _ = self?.runAdb(["kill-server"])
                _ = self?.runAdb(["start-server"])
            }
        }

        qrPairingTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.pollForPairingService()
        }
        RunLoop.main.add(timer, forMode: .common)
        qrPairingTimer = timer
    }

    func cancelQRPairing() {
        qrPairingTimer?.invalidate()
        qrPairingTimer = nil
        qrPairingPayload = nil
        qrPairingCode = nil
        qrPairingDeadline = nil
        qrPairingStatus = ""
        LogManager.shared.log("ADB QR: Pairing cancelled")
    }

    /// One line of `adb mdns services` looks like:
    ///   `adb-XXXX-YYYY\t_adb-tls-pairing._tcp\t192.168.1.5:41234`
    private func mdnsAddress(ofType type: String, in output: String) -> String? {
        for line in output.components(separatedBy: "\n") where line.contains(type) {
            if let addr = line.components(separatedBy: "\t").last?
                .trimmingCharacters(in: .whitespaces), addr.contains(":") {
                return addr
            }
        }
        return nil
    }

    private func pollForPairingService() {
        if let deadline = qrPairingDeadline, Date() > deadline {
            qrPairingStatus = tr("Timed out. Check Wireless debugging is on, then try again.")
            qrPairingFailed = true
            qrPairingTimer?.invalidate()
            qrPairingTimer = nil
            LogManager.shared.log("ADB QR: Timed out waiting for the pairing service")
            return
        }
        guard let code = qrPairingCode else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let services = self.runAdb(["mdns", "services"])
            guard let addr = self.mdnsAddress(ofType: "_adb-tls-pairing._tcp", in: services.output) else { return }

            DispatchQueue.main.async {
                self.qrPairingTimer?.invalidate()
                self.qrPairingTimer = nil
                self.qrPairingStatus = tr("Pairing…")
                LogManager.shared.log("ADB QR: Found pairing service at \(addr) — pairing")
            }

            let pair = self.runAdb(["pair", addr, code])
            let paired = pair.success && pair.output.lowercased().contains("successfully")
            guard paired else {
                DispatchQueue.main.async {
                    self.qrPairingStatus = tr("Pairing failed. Generate a new code and rescan.")
                    self.qrPairingFailed = true
                    LogManager.shared.log("ADB QR: Pair failed: \(pair.output.isEmpty ? "(no output)" : pair.output)")
                }
                return
            }
            LogManager.shared.log("ADB QR: Paired ✅")

            // The phone switches to advertising the connect service once paired.
            var connectAddr: String?
            for _ in 0..<10 {
                let s = self.runAdb(["mdns", "services"])
                if let a = self.mdnsAddress(ofType: "_adb-tls-connect._tcp", in: s.output) {
                    connectAddr = a
                    break
                }
                Thread.sleep(forTimeInterval: 1.0)
            }
            guard let connectAddr = connectAddr else {
                DispatchQueue.main.async {
                    self.qrPairingStatus = tr("Paired, but the device never appeared. Try Connect again.")
                    self.qrPairingFailed = true
                    LogManager.shared.log("ADB QR: Paired but no _adb-tls-connect._tcp appeared")
                }
                return
            }

            let connect = self.runAdb(["connect", connectAddr])
            LogManager.shared.log("ADB QR: connect \(connectAddr) — \(connect.output)")

            DispatchQueue.main.async {
                self.qrPairingPayload = nil
                self.qrPairingCode = nil
                self.qrPairingStatus = ""
                // adb now lists a Wi-Fi device, which this already knows how to tunnel.
                self.connectADBWireless()
            }
        }
    }

    func connectADBWireless() {
        guard !adbInProgress else { return }
        adbInProgress = true
        adbStatus = tr("Checking device...")

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
                    self.adbStatus = tr("Setting up wireless tunnel...")
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
                let forwardResult = self.runAdb(["-s", wifiSerial, "forward", "tcp:\(BCConstants.adbForwardPort)", "tcp:\(BCConstants.tcpPort)"])
                LogManager.shared.log("ADB Wireless: forward result: \(forwardResult.output)")
                self.ensureReceiverAppRunning(serial: wifiSerial)

                DispatchQueue.main.async {
                    self.adbStatus = tr("Connecting stream...")
                    LogManager.shared.log("ADB Wireless: Tunnel ready via existing WiFi — connecting to localhost:\(BCConstants.adbForwardPort)")
                    self.connectADBTunnel(displayName: "Android (WiFi ADB)")

                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self.adbStatus = tr("Wireless ADB active")
                        self.adbInProgress = false
                    }
                }
                return
            }

            // No WiFi ADB — need USB device to do the handoff
            guard !usbLines.isEmpty else {
                DispatchQueue.main.async {
                    self.adbStatus = tr("No USB or WiFi device found")
                    self.adbInProgress = false
                    LogManager.shared.log("ADB Wireless: No USB or WiFi ADB device connected")
                }
                return
            }

            let serial = usbLines[0].components(separatedBy: "\t").first ?? ""
            DispatchQueue.main.async {
                self.adbStatus = tr("Found: %@", serial)
                LogManager.shared.log("ADB Wireless: Found USB device \(serial)")
            }

            // 2. Get device IP over USB (pass serial to avoid "more than one device" error)
            guard let deviceIP = self.getDeviceIP(serial: serial) else {
                DispatchQueue.main.async {
                    self.adbStatus = tr("Cannot get device IP")
                    self.adbInProgress = false
                    LogManager.shared.log("ADB Wireless: Failed to get device IP via 'ip route'")
                }
                return
            }

            DispatchQueue.main.async {
                self.adbStatus = tr("Device IP: %@", deviceIP)
                LogManager.shared.log("ADB Wireless: Device IP is \(deviceIP)")
            }

            // 3. Disconnect existing ADB connection first (tcpip will kill USB tunnel anyway)
            DispatchQueue.main.async {
                self.adbStatus = tr("Switching to wireless — disconnecting USB...")
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
                self.adbStatus = tr("Switching to wireless — enabling TCP mode...")
                LogManager.shared.log("ADB Wireless: Running 'adb tcpip 5555'...")
            }
            let tcpipResult = self.runAdb(["-s", serial, "tcpip", "5555"])
            LogManager.shared.log("ADB Wireless: tcpip result: \(tcpipResult.output)")

            // Wait for ADB daemon to restart
            Thread.sleep(forTimeInterval: 3.0)

            // 5. Connect to device over WiFi
            DispatchQueue.main.async {
                self.adbStatus = tr("Switching to wireless — connecting %@...", deviceIP)
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
                    self.adbStatus = tr("WiFi connect failed — check WiFi")
                    self.adbInProgress = false
                    LogManager.shared.log("ADB Wireless: Failed to connect over WiFi after 10 attempts")
                }
                return
            }

            // 6. Set up port forwarding (through the WiFi ADB connection)
            DispatchQueue.main.async {
                self.adbStatus = tr("Switching to wireless — setting up tunnel...")
                LogManager.shared.log("ADB Wireless: Setting up port forward on \(deviceIP):5555...")
            }
            let forwardResult = self.runAdb(["-s", "\(deviceIP):5555", "forward", "tcp:\(BCConstants.adbForwardPort)", "tcp:\(BCConstants.tcpPort)"])
            LogManager.shared.log("ADB Wireless: forward result: \(forwardResult.output)")

            // 7. Connect sender to the forwarded host port (tunneled through WiFi ADB)
            DispatchQueue.main.async {
                self.adbStatus = tr("Connecting stream...")
                LogManager.shared.log("ADB Wireless: Tunnel ready — connecting to localhost:\(BCConstants.adbForwardPort)")
                self.connectADBTunnel(displayName: "Android (WiFi ADB)")

                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.adbStatus = tr("Wireless ADB active")
                    self.adbInProgress = false
                    LogManager.shared.log("ADB Wireless: Setup complete — streaming via WiFi ADB tunnel")
                }
            }
        }
    }

    // MARK: - Manual entries

    /// Names the user has dismissed from the list. Needed because mDNS rows are
    /// rebuilt from browse results every callback, so simply deleting one would
    /// have it reappear a second later.
    ///
    /// A dismissal is dropped once the record actually leaves the browse results,
    /// so a device that genuinely comes back is shown again. Bonjour caches a
    /// record for its full TTL after a device vanishes without sending goodbye
    /// packets — which is what happens when Wi-Fi is switched off — so these ghosts
    /// can linger for an hour and cannot be told apart from a live device by name.
    private var dismissedServiceNames: Set<String> = []

    /// Forget a device row. Disconnects first when it is live, otherwise the row
    /// would disappear while its stream kept running in the background.
    func removeService(_ service: DiscoveredService) {
        if connectedServices.contains(where: { $0.name == service.name }) {
            disconnectService(service)
        }
        dismissedServiceNames.insert(service.name)
        foundServices.removeAll { $0.name == service.name }
        LogManager.shared.log("Sender: Removed '\(service.name)' from the device list")
    }

    // MARK: - USB presence

    private static let adbUSBName = "Android (USB)"

    /// Offer a USB-attached Android even with no network at all.
    ///
    /// Discovery is mDNS, which needs Wi-Fi; the ADB tunnel is loopback over the
    /// cable and needs none. Without this, a plugged-in phone never appears in the
    /// list when Wi-Fi is off, and the app looks broken when it is merely undiscovered.
    func startADBUSBWatch() {
        adbPollTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            self?.refreshADBUSBPresence()
        }
        RunLoop.main.add(timer, forMode: .common)
        adbPollTimer = timer
        refreshADBUSBPresence()
    }

    private func refreshADBUSBPresence() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let devices = self.runAdb(["devices"])
            let hasUSB = devices.output.components(separatedBy: "\n").contains {
                $0.contains("\tdevice") && !$0.contains(":") && !$0.hasPrefix("emulator-")
            }
            DispatchQueue.main.async {
                let name = NetworkClient.adbUSBName
                let listed = self.foundServices.contains { $0.name == name }
                // Don't touch the list while a tunnel is live — the connected row owns it.
                let live = self.connectedDisplays.contains { $0.name.contains("Android (") }
                if hasUSB && !listed && !live {
                    guard let port = NWEndpoint.Port(rawValue: BCConstants.adbForwardPort) else { return }
                    let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host("localhost"), port: port)
                    self.foundServices.append(DiscoveredService(name: name, endpoint: endpoint))
                    LogManager.shared.log("ADB USB: Device attached — offering '\(name)' (no network needed)")
                } else if !hasUSB && listed && !live {
                    self.foundServices.removeAll { $0.name == name }
                    LogManager.shared.log("ADB USB: Device detached — removing '\(name)'")
                }
            }
        }
    }

    /// Make sure the receiver app is actually running before opening the tunnel.
    ///
    /// `adb forward` accepts the Mac's local connection immediately whether or not
    /// anything is listening on the phone, then drops it when the forward fails. That
    /// surfaces as "connected, sent a few frames, Connection reset by peer" — which
    /// looks like a streaming bug but just means the app was closed. We have ADB, so
    /// launch it rather than relying on the user to remember.
    private func ensureReceiverAppRunning(serial: String?) {
        var prefix = [String]()
        if let serial = serial { prefix += ["-s", serial] }

        // Already running? Leave it alone. Relaunching a live receiver used to stack a
        // second activity on the first, and the two fought over the listening port.
        // The manifest now pins the app to a single instance, but skipping the launch
        // also avoids yanking the app to the foreground mid-stream.
        let running = runAdb(prefix + ["shell", "pidof", "com.bettercast.receiver"])
        if running.success, !running.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            LogManager.shared.log("ADB: Receiver app already running on the phone")
            return
        }

        // --activity-single-top reuses the existing task rather than starting
        // another copy on top of it.
        let args = prefix + [
            "shell", "am", "start", "--activity-single-top",
            "-n", "com.bettercast.receiver/.MainActivity"
        ]
        let result = runAdb(args)
        if result.success {
            LogManager.shared.log("ADB: Launched the receiver app on the phone")
        } else {
            LogManager.shared.log("ADB: Could not launch the receiver app — \(result.output)")
        }
        // Give the activity a moment to bind its listening socket.
        Thread.sleep(forTimeInterval: 1.2)
    }

    /// Quick ADB USB-only: just forward port and connect (no wireless handoff)
    func connectADBUSB() {
        adbStatus = tr("Forwarding port...")
        LogManager.shared.log("ADB USB: Setting up port forward...")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // Find USB device serial (filter out wireless connections which contain ":")
            let devices = self.runAdb(["devices"])
            let usbLines = devices.output.components(separatedBy: "\n").filter {
                $0.contains("\tdevice") && !$0.contains(":") && !$0.hasPrefix("emulator-")
            }
            // Detect a connected-but-unauthorized device so we can give a precise hint.
            let unauthorized = devices.output.components(separatedBy: "\n").contains {
                $0.contains("\tunauthorized") || $0.contains("\tno permissions")
            }
            let serial = usbLines.first?.components(separatedBy: "\t").first

            guard let serial = serial else {
                DispatchQueue.main.async {
                    if unauthorized {
                        self.adbStatus = tr("USB device unauthorized — tap 'Allow' on the phone")
                        LogManager.shared.log("ADB USB: Device detected but unauthorized. Unlock the phone and accept the 'Allow USB debugging?' prompt, then retry.")
                    } else {
                        self.adbStatus = tr("No USB device — enable USB debugging")
                        LogManager.shared.log("ADB USB: No device found via 'adb devices'. Enable Developer Options → USB debugging, connect a data cable, and authorize this Mac, then retry.")
                    }
                    self.adbInProgress = false
                }
                return
            }

            // -s serial pins the forward to this device (handles multiple-device case)
            let forwardResult = self.runAdb(["-s", serial, "forward", "tcp:\(BCConstants.adbForwardPort)", "tcp:\(BCConstants.tcpPort)"])
            guard forwardResult.success else {
                DispatchQueue.main.async {
                    self.adbStatus = tr("Port forward failed")
                    LogManager.shared.log("ADB USB: forward failed: \(forwardResult.output.isEmpty ? "(no output)" : forwardResult.output)")
                    self.adbInProgress = false
                }
                return
            }
            LogManager.shared.log("ADB USB: forward tcp:\(BCConstants.adbForwardPort) → tcp:\(BCConstants.tcpPort) on \(serial)")
            self.ensureReceiverAppRunning(serial: serial)

            DispatchQueue.main.async {
                self.adbStatus = tr("Connecting...")
                self.connectADBTunnel(displayName: "Android (USB)")

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.adbStatus = tr("USB ADB active")
                    LogManager.shared.log("ADB USB: Tunnel established — connecting stream")
                }
            }
        }
    }

    /// Connect to ADB-forwarded port with a proper device name that shows in the device list
    private func connectADBTunnel(displayName: String) {
        guard let port = NWEndpoint.Port(rawValue: BCConstants.adbForwardPort) else { return }
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("localhost"),
            port: port
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

        LogManager.shared.log("Sender: ADB connect '\(displayName)' via localhost:\(BCConstants.adbForwardPort)")
        connectWithParameters(service: service, parameters: parameters, forceTCP: true)
    }

    private func connectWithParameters(service: DiscoveredService, parameters: NWParameters, forceTCP: Bool = false) {
        if connectedServices.contains(where: { $0.name == service.name }) {
            LogManager.shared.log("Sender: Already connected to \(service.name)")
            return
        }

        // Mark as connecting to prevent auto-connect races during retry
        markConnecting(service.name)

        let deviceCount = pipelines.count + 1
        self.status = "Connecting to \(service.name) (Device #\(deviceCount))..."

        let connection = NWConnection(to: service.endpoint, using: parameters)
        let connectionId = UUID()

        connection.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    self?.unmarkConnecting(service.name)
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
                    // Match Mac/iOS Swift receivers that don't handle the type byte.
                    // Bonjour appends " (2)", " (3)" etc. for duplicate names, so we can't use exact match.
                    // Android/Windows/Linux receivers contain their platform keyword and DO support typeByte.
                    let nameLower = service.name.lowercased()
                    let isLegacyReceiver = nameLower.hasPrefix("bettercast receiver")
                        && !nameLower.contains("android") && !nameLower.contains("windows") && !nameLower.contains("linux")
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
                    self?.unmarkConnecting(service.name)
                    // If the connection failed before .ready, no pipeline exists, so
                    // removeConnection() can't cancel it — do it here so the NWConnection
                    // is released and its self-retain cycle broken.
                    connection.cancel()
                    connection.stateUpdateHandler = nil
                    self?.removeConnection(connectionId)

                    let remaining = self?.pipelines.count ?? 0
                    if remaining == 0 {
                        self?.status = "All connections failed"
                    } else {
                        self?.status = "Connected to \(remaining) device(s)"
                    }
                case .cancelled:
                    self?.unmarkConnecting(service.name)
                    self?.removeConnection(connectionId)
                    connection.stateUpdateHandler = nil
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
        screenCapture.executableURL = URL(fileURLWithPath: BCConstants.tccutilPath)
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
        accessibility.executableURL = URL(fileURLWithPath: BCConstants.tccutilPath)
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
        // Break the NWConnection self-retain cycle: the stateUpdateHandler closure
        // strongly captures `connection`, so without this the connection (and its
        // queues/buffers) never deallocates after cancel. This was leaking one
        // NWConnection graph per disconnect.
        pipeline.connection.stateUpdateHandler = nil
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
            pipeline.connection.stateUpdateHandler = nil // Break self-retain cycle (see removeConnection)
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

    /// Switch an already-connected Android device to the ADB USB tunnel (lower latency, higher
    /// bandwidth). Drops the current connection, then sets up USB. Requires the device plugged
    /// in via USB — connectADBUSB() reports "No USB device" if it isn't.
    func switchAndroidToUSB(from connectionId: UUID) {
        LogManager.shared.log("Sender: Switching Android connection to USB…")
        removeConnection(connectionId)
        // Let teardown settle before adb forward + reconnect.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.connectADBUSB()
        }
    }

    /// Switch an already-connected Android device (currently on USB) to a wireless ADB tunnel.
    /// connectADBWireless() does the USB→tcpip→WiFi handoff and tears down the USB tunnel itself.
    func switchAndroidToWireless(from connectionId: UUID) {
        LogManager.shared.log("Sender: Switching Android connection to wireless…")
        connectADBWireless()
    }

    func setAudioEnabled(_ enabled: Bool, for connectionId: UUID) {
        if let idx = connectedDisplays.firstIndex(where: { $0.id == connectionId }) {
            connectedDisplays[idx].audioEnabled = enabled
            let name = connectedDisplays[idx].name
            LogManager.shared.log("Sender: Audio \(enabled ? "enabled" : "disabled") for \(name)")
        }
    }

    /// Toggle the looser burst ceiling for one receiver, live — no reconnect needed.
    func setSmoothMotion(_ enabled: Bool, for connectionId: UUID) {
        if let idx = connectedDisplays.firstIndex(where: { $0.id == connectionId }) {
            connectedDisplays[idx].smoothMotion = enabled
            let name = connectedDisplays[idx].name
            pipelines[connectionId]?.videoEncoder?.setBurstMultiplier(enabled ? 3.0 : 1.5)
            LogManager.shared.log("Sender: Smooth motion \(enabled ? "on (3.0x burst)" : "off (1.5x burst)") for \(name)")
        }
    }

    func updateConnectedDisplays() {
        connectedDisplays = pipelines.map { (id, pipeline) in
            let bounds = InputHandler.shared.getDisplayBounds(for: id)
            let res = bounds.width > 0 ? "\(Int(bounds.width))x\(Int(bounds.height))" : tr("Initializing...")
            return ConnectedDisplayInfo(
                id: id,
                name: pipeline.service.name,
                resolution: res,
                displayBounds: bounds,
                audioEnabled: connectedDisplays.first(where: { $0.id == id })?.audioEnabled ?? audioStreamingEnabled,
                smoothMotion: connectedDisplays.first(where: { $0.id == id })?.smoothMotion ?? false,
                cgDisplayID: pipeline.virtualDisplayManager?.displayID
            )
        }
    }
    
    private func startStatsTimer() {
        // Exactly one timer, however many receivers connect. This is called from every
        // connection path; without the guard each new device added another 1 Hz pass over
        // adaptBitrates(), and they fought each other for the same counters.
        guard statsTimer == nil else { return }

        // Simple timer to update transfer rate UI
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            if self.pipelines.isEmpty {
                timer.invalidate()
                self.statsTimer = nil
                return
            }
            
            let bytes = self.bytesSentWindow
            self.bytesSentWindow = 0

            let mbps = Double(bytes * 8) / 1_000_000.0
            self.transferRate = String(format: "%.1f Mbps", mbps)

            self.adaptBitrates()
        }
    }

    /// Adaptive bitrate for links that can actually run out of room: match the encoder's
    /// rate to what the link carries. P2P (AWDL) and USB ADB have plenty of headroom and
    /// keep full quality. Wireless ADB does NOT — the local socket is on lo0, but the
    /// bytes still cross Wi-Fi, so it is steered like any other Wi-Fi link. Backs off fast
    /// on drops, recovers gently when clear — hysteresis prevents oscillation. Floor keeps
    /// motion smooth over a weak link.
    /// One line per receiver per second: fps, Mbps, average capture-to-emit age, drops.
    ///
    /// Same four numbers SideScreen prints, measured the same way, so the two logs can be
    /// laid side by side. Ours previously logged a byte count every 300 frames, which at
    /// 60fps is one sample per five seconds and tells you nothing about a moving scene.
    private func logPipelineStats() {
        for p in pipelines.values {
            guard let enc = p.videoEncoder, enc.statsFrames > 0 else { continue }
            let fps = Double(enc.statsFrames)
            let mbps = Double(enc.statsBytes) * 8.0 / 1_000_000.0
            // 0.7/0.3 smoothing: reacts within ~3s, ignores single-second spikes.
            enc.smoothedBps = enc.smoothedBps * 0.7 + Double(enc.statsBytes) * 8.0 * 0.3
            let avgAge = enc.statsAgeCount > 0 ? enc.statsAgeSumMs / Double(enc.statsAgeCount) : 0
            LogManager.shared.log(String(format: "Pipeline %@: %.1ffps, %.1fMbps, avg frame age: %.1fms, skipped: %d, target: %.1fMbps",
                p.service.name, fps, mbps, avgAge, enc.adaptDrops, Double(enc.currentBitrate) / 1_000_000.0))
            enc.statsFrames = 0
            enc.statsBytes = 0
            enc.statsAgeSumMs = 0
            enc.statsAgeCount = 0
        }
    }

    private func adaptBitrates() {
        logPipelineStats()
        let floorBitrate = 2_000_000 // 2 Mbps — smooth-but-soft rather than blocky

        // Every wireless receiver shares one radio on this Mac, AWDL included: the Wi-Fi
        // chip time-slices between the AP channel and the AWDL social channel, so a P2P
        // stream and an infrastructure stream are not independent links.
        //
        // Without a shared budget each pipeline asks for the full user-selected bitrate,
        // and the two are not treated alike: P2P never backs off, so the infrastructure
        // device absorbs all the contention. Measured on an iPhone + Android pair — the
        // Android fell 18 → 2 Mbps (its floor) within seven seconds of the iPhone
        // connecting, and climbed straight back the moment it left, while the iPhone held
        // 20 Mbps at 2532x1170 throughout. Splitting the ceiling makes them share.
        //
        // USB ADB is excluded: it is a cable and takes nothing from the radio.
        let radioPipelines = pipelines.values.filter { !$0.isLoopback || $0.isWiFiADB }
        // Demand-based sharing rather than an equal cut. Each pipeline's ceiling is the
        // full budget minus what the OTHERS are measured to be using, clamped between
        // its fair share and the full budget. An idle screen spends almost nothing, so
        // its neighbour can borrow nearly everything; the moment the idle one wakes up,
        // its own ceiling is still guaranteed at fair share and the borrower is pulled
        // back within a couple of smoothing periods. With one receiver this reduces to
        // exactly the old behaviour.
        let budget = Double(selectedQuality.rawValue)
        let fairShare = max(Double(floorBitrate * 2), budget / Double(max(radioPipelines.count, 1)))
        for p in radioPipelines {
            guard let enc = p.videoEncoder else { continue }
            let othersUse = radioPipelines
                .filter { $0.service.name != p.service.name }
                .compactMap { $0.videoEncoder?.smoothedBps }
                .reduce(0, +)
            let ceiling = Int(min(budget, max(fairShare, budget - othersUse)))
            if enc.maxBitrate != ceiling {
                let announce = abs(Double(enc.maxBitrate) - Double(ceiling)) > 2_000_000
                enc.maxBitrate = ceiling
                if announce {
                    LogManager.shared.log(String(format: "Sender: Bitrate ceiling %@: %.1f Mbps (%d wireless receivers, others using %.1f)",
                        p.service.name, Double(ceiling) / 1_000_000, radioPipelines.count, othersUse / 1_000_000))
                }
            }
            // Pull an over-budget stream down immediately. P2P has no drop signal of its
            // own to steer by, so this is the only thing that makes it yield.
            if enc.currentBitrate > ceiling {
                enc.setTargetBitrate(ceiling)
            }
        }

        // Collect (name, encoder) up front so we never mutate `pipelines` while iterating it,
        // and so all adaptive state reads/writes go through the encoder (a class), not the
        // shared dictionary. Mutating the dict here while the encoder callback thread also
        // touches it corrupts the heap (was the v11 crash).
        let targets: [(name: String, encoder: VideoEncoder)] = pipelines.values.compactMap { p in
            guard !p.isP2P, !p.isLoopback || p.isWiFiADB,
                  let enc = p.videoEncoder, enc.maxBitrate > 0 else { return nil }
            return (p.service.name, enc)
        }
        for (name, enc) in targets {
            // Wait for a real sample rather than resetting every tick. A static screen
            // encodes only a handful of frames per second, and judging a 30% bitrate cut
            // on "1 drop out of 5 frames" is noise, not signal — that is what made the
            // rate pump up and down several times a second. Counters keep accumulating
            // across ticks until there are enough frames to mean something.
            let frames = enc.adaptFrames
            let drops = enc.adaptDrops
            guard frames >= 30 else { continue }
            enc.adaptFrames = 0
            enc.adaptDrops = 0

            let current = enc.currentBitrate
            let dropRatio = Double(drops) / Double(frames)
            var target = current
            // Threshold sits above the link's natural noise floor, not at it.
            //
            // A backpressure drop only means the previous send had not completed within
            // one frame interval — 16.7ms at 60fps. Ordinary Wi-Fi jitter clears that bar
            // regularly, and measurement shows it is not a bitrate signal at all: on a
            // single direct connection the drop ratio held at 16-21% across 20.0, 14.0,
            // 9.8, 8.9, 6.2 and 4.3 Mbps — flat while the bitrate fell fivefold. The old
            // 0.15 threshold sat just under that floor, so the controller tripped on
            // nothing and sawtoothed 20 → 3 → 20 Mbps with one device connected.
            // Genuine trouble looks nothing like it: blackout windows run 50-95%.
            if dropRatio > 0.35 {
                // Only keep cutting while cutting is demonstrably helping.
                //
                // Backpressure drops mean "the previous send was still in flight", which
                // congestion causes — but so does airtime starvation, and those look
                // identical from here. When the Wi-Fi chip is time-slicing to AWDL, sends
                // stall for tens of milliseconds no matter how small the frame is.
                // Measured on this link: 22/43 drops at 10 Mbps, still 21/66 at 2 Mbps
                // after five compounding cuts — five times less data, same drop ratio.
                // Cutting further just destroys the picture and buys nothing.
                let previous = enc.lastAdaptDropRatio
                let cuttingHelps = previous < 0 || dropRatio < previous - 0.05
                if cuttingHelps {
                    target = max(floorBitrate, Int(Double(current) * 0.7)) // back off 30%
                    enc.lastAdaptDropRatio = dropRatio
                    enc.adaptHolding = false
                } else if !enc.adaptHolding {
                    // Held deliberately — say so once rather than looking stuck.
                    enc.adaptHolding = true
                    LogManager.shared.log(String(format: "Sender: Holding bitrate %@ at %.1f Mbps — drops %d/%d are not bandwidth-related",
                        name, Double(current) / 1_000_000, drops, frames))
                }
            } else if dropRatio < 0.20 && current < enc.maxBitrate {
                // Recover on "quiet enough", not on "perfectly clean". Requiring zero
                // drops is unreachable on a link whose noise floor is ~17%, so the rate
                // ratcheted down at the first burst and never climbed back — measured
                // stuck at 14 Mbps for a whole session after one startup keyframe spike.
                // The gap between this and the 0.35 cut threshold is deliberate
                // hysteresis, so it neither oscillates nor sits pinned low.
                enc.lastAdaptDropRatio = -1 // clean window; a later spike may cut again
                enc.adaptHolding = false
                target = min(enc.maxBitrate, current + enc.maxBitrate / 10) // recover ~10%/s
            } else {
                enc.lastAdaptDropRatio = -1
                enc.adaptHolding = false
            }

            if target != current {
                enc.setTargetBitrate(target)
                LogManager.shared.log(String(format: "Sender: Adaptive bitrate %@: %.1f→%.1f Mbps (drops %d/%d)",
                    name, Double(current) / 1_000_000, Double(target) / 1_000_000, drops, frames))
            }
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
                    // ECANCELED means we already initiated teardown — don't recurse.
                    // For a real peer drop, tear down now so capture/encoders stop
                    // immediately instead of waiting on (or missing) the 15s reaper.
                    if code != .ECANCELED {
                        DispatchQueue.main.async { self?.removeConnection(connectionId) }
                    }
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
                                } else if event.type == .command && event.keyCode == 777 {
                                    // Screen info from receiver: deltaX=width, deltaY=height (pixels)
                                    self?.handleScreenInfo(for: connectionId, width: Int(event.deltaX), height: Int(event.deltaY))
                                } else if event.type == .command && event.keyCode == 770,
                                          let name = event.deviceName,
                                          !name.isEmpty {
                                    self?.handleDeviceHello(connectionId: connectionId, deviceName: name)
                                } else if event.type == .command && event.keyCode >= 600 && event.keyCode <= 603 {
                                    if self?.isDuplicateEvent(event.eventId) == false {
                                        InputHandler.shared.postTrackpadShortcut(keyCode: event.keyCode)
                                    }
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
                            } else if event.type == .command && event.keyCode == 777 {
                                self?.handleScreenInfo(for: connectionId, width: Int(event.deltaX), height: Int(event.deltaY))
                            } else if event.type == .command && event.keyCode == 770,
                                      let name = event.deviceName,
                                      !name.isEmpty {
                                self?.handleDeviceHello(connectionId: connectionId, deviceName: name)
                            } else if event.type == .command && event.keyCode >= 600 && event.keyCode <= 603 {
                                if self?.isDuplicateEvent(event.eventId) == false {
                                    InputHandler.shared.postTrackpadShortcut(keyCode: event.keyCode)
                                }
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
    
    /// Handle a device-name hello (command 770) from an invite-initiated iOS receiver.
    /// We close the invite pipeline and re-dial via the matching `_bettercast._tcp`
    /// Bonjour service so the connection picks up the proper name and AWDL P2P
    /// routing (using the existing outbound-dial path's interface pinning).
    private func handleDeviceHello(connectionId: UUID, deviceName: String) {
        guard let existing = pipelines[connectionId] else { return }

        // The whole point of re-dialing is to upgrade an infrastructure connection
        // onto AWDL. If the invite already arrived over AWDL there is nothing to
        // upgrade — tearing it down to chase a link we already have just destroys a
        // working stream, and the re-dial then times out because the outbound path
        // bans infrastructure. Keep the connection and only fix up the display name.
        if existing.isP2P {
            if existing.service.name != deviceName {
                let renamed = DiscoveredService(name: deviceName, endpoint: existing.service.endpoint)
                pipelines[connectionId]?.service = renamed
                if let idx = connectedServices.firstIndex(where: { $0.name == existing.service.name }) {
                    connectedServices[idx] = renamed
                }
            }
            LogManager.shared.log("Sender: Device hello '\(deviceName)' — invite is already P2P/AWDL, keeping it ✅")
            return
        }

        // Prefer the " P2P" variant when available — it's the AWDL listener.
        let p2pName = "\(deviceName) P2P"
        let target: DiscoveredService?
        if let p2p = foundServices.first(where: { $0.name == p2pName }) {
            target = p2p
        } else if let plain = foundServices.first(where: { $0.name == deviceName }) {
            target = plain
        } else {
            target = nil
        }

        guard let target = target else {
            LogManager.shared.log("Sender: Device hello — no matching browse entry for '\(deviceName)'; keeping invite pipeline")
            return
        }

        // Don't re-dial if we're already in the middle of connecting to the same name.
        if connectedServices.contains(where: { $0.name == target.name }) ||
           connectingServiceNames.contains(target.name) {
            LogManager.shared.log("Sender: Device hello — already connected/connecting to \(target.name); dropping invite duplicate")
            removeConnection(connectionId)
            return
        }

        LogManager.shared.log("Sender: Device hello '\(deviceName)' → re-dialing as \(target.name)")
        removeConnection(connectionId)
        connect(to: target)
    }

    // Handle screen info from iOS receiver (command 777)
    // Receiver reports its native screen dimensions so we can match the aspect ratio
    private func handleScreenInfo(for connectionId: UUID, width: Int, height: Int) {
        guard width > 0 && height > 0 else { return }
        guard let pipeline = pipelines[connectionId] else { return }

        let serviceName = pipeline.service.name

        // Command 777 is sent by iOS/Mac Swift receivers to report screen dimensions.
        // These receivers now support type-byte framing (auto-detect), so keep supportsTypeByte = true.
        LogManager.shared.log("Sender: Screen info (command 777) from \(serviceName)")

        let oldW = pipeline.reportedScreenWidth
        let oldH = pipeline.reportedScreenHeight

        // Skip if dimensions haven't changed
        if oldW == width && oldH == height { return }

        pipelines[connectionId]?.reportedScreenWidth = width
        pipelines[connectionId]?.reportedScreenHeight = height
        LogManager.shared.log("Sender: Screen info from \(serviceName): \(width)x\(height)")

        // Restart pipeline with new dimensions
        stopPipeline(for: connectionId)
        startPipeline(for: connectionId)
    }

    private func stopPipeline(for connectionId: UUID) {
        pipelines[connectionId]?.screenRecorder?.stopCapture()
        pipelines[connectionId]?.screenRecorder = nil
        pipelines[connectionId]?.videoEncoder = nil
        pipelines[connectionId]?.audioEncoder = nil
        if let dm = pipelines[connectionId]?.virtualDisplayManager {
            dm.destroyDisplay()
            pipelines[connectionId]?.virtualDisplayManager = nil
        }
    }

    func startPipeline(for connectionId: UUID) {
        guard pipelines[connectionId] != nil else { return }

        let serviceName = pipelines[connectionId]?.service.name ?? "unknown"
        LogManager.shared.log("Sender: Starting pipeline for \(serviceName)...")

        // Defensive teardown: this function overwrites screenRecorder/virtualDisplayManager
        // below. If the pipeline already owns live ones (startPipeline ran again without a
        // paired stopPipeline — e.g. a reconnect race or a repeated screen-info report), the
        // old ScreenRecorder + virtual display would be detached but keep running. Nothing in
        // `pipelines` would point at them, so neither the heartbeat timeout nor the Disconnect
        // button could reach them — they'd capture/pump forever and the virtual screen would
        // linger until the app quits. Stop them before replacing the references.
        if let oldRecorder = pipelines[connectionId]?.screenRecorder {
            oldRecorder.stopCapture()
            pipelines[connectionId]?.screenRecorder = nil
        }
        if let oldDisplay = pipelines[connectionId]?.virtualDisplayManager {
            oldDisplay.destroyDisplay()
            pipelines[connectionId]?.virtualDisplayManager = nil
        }

        var targetDisplayID: CGDirectDisplayID? = nil

        // Create virtual display if enabled
        if useVirtualDisplay {
            LogManager.shared.log("Sender: Creating virtual display for \(serviceName)...")
            let displayManager = VirtualDisplayManager()

            // Use receiver-reported screen dimensions if available (matches device aspect ratio)
            let resolution: VirtualDisplayManager.Resolution
            if let rw = pipelines[connectionId]?.reportedScreenWidth,
               let rh = pipelines[connectionId]?.reportedScreenHeight, rw > 0 && rh > 0 {
                // Reported dims are the device's native PIXELS: pass through unchanged.
                // With hiDPI the mode is halved, landing on the device's point size.
                LogManager.shared.log("Sender: Using device-reported resolution \(rw)x\(rh) for \(serviceName)")
                resolution = VirtualDisplayManager.Resolution(
                    width: rw,
                    height: rh,
                    ppi: isRetina ? min(220, selectedResolution.ppi * 2) : selectedResolution.ppi,
                    hiDPI: isRetina,
                    name: "BetterCast Display (\(serviceName))"
                )
            } else {
                // The picker value is the LOOKS-LIKE size the user expects to see.
                // For Retina, double the framebuffer rather than letting hiDPI halve
                // the visible resolution: 2560x1600 + Retina used to come up as a
                // "1280 x 800" display while capture ran at 4x the framebuffer
                // (5120x3200 upscaled) — the "stuck at 1280x800, unusable" report in
                // issue #40. Doubling here also makes the capture size
                // (selectedResolution * 2 below) match the framebuffer exactly.
                let scale = isRetina ? 2 : 1
                resolution = VirtualDisplayManager.Resolution(
                    width: selectedResolution.width * scale,
                    height: selectedResolution.height * scale,
                    ppi: selectedResolution.ppi * scale,
                    hiDPI: isRetina,
                    name: "BetterCast Display (\(serviceName))"
                )
            }

            // High-refresh receivers: create the virtual display at 120Hz when the user
            // picked 120fps, so capture actually has 120 unique frames to deliver.
            if let displayID = displayManager.createDisplay(resolution: resolution, refreshRate: selectedFPS >= 120 ? 120 : 60) {
                targetDisplayID = displayID
                pipelines[connectionId]?.virtualDisplayManager = displayManager

                // Update InputHandler with this connection's display bounds
                // Retry with increasing delays — macOS may take time to register the virtual display
                func pollDisplayBounds(attempt: Int) {
                    // Abort if this connection has been replaced by a newer pipeline (e.g. after the
                    // iOS receiver reports its screen size, startPipeline runs again with a new
                    // virtual display). Without this check, the stale poll for the destroyed display
                    // would clobber the new pipeline's correct bounds with a fallback rect.
                    guard self.pipelines[connectionId]?.virtualDisplayManager?.displayID == displayID else {
                        LogManager.shared.log("Sender: Aborting bounds poll for stale display \(displayID) (\(serviceName))")
                        return
                    }
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
                        // Fallback: use the looks-like size of the display we requested
                        // (bounds are in points; hiDPI halves the pixel dimensions)
                        let scale = resolution.hiDPI ? 2 : 1
                        let fallbackBounds = CGRect(x: 0, y: 0, width: resolution.width / scale, height: resolution.height / scale)
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
        // Use reported screen dimensions if available (already in pixels)
        let captureWidth: Int
        let captureHeight: Int
        if let rw = pipelines[connectionId]?.reportedScreenWidth,
           let rh = pipelines[connectionId]?.reportedScreenHeight, rw > 0 && rh > 0 {
            captureWidth = rw
            captureHeight = rh
        } else {
            // Capture at the chosen resolution even when Retina is on. The virtual
            // display is still created at 2x so macOS renders crisply, but encoding
            // 4x the pixels at the same bitrate handed non-Apple receivers a 4K60
            // stream they cannot decode — 1920x1080 + Retina became 3840x2160 and
            // stuttered. Downsampling from the 2x framebuffer supersamples instead,
            // which looks better than a plain 1x capture at the same bitrate.
            //
            // Receivers that report their own dimensions (iOS does, via command 777)
            // take the branch above and stream at their true native resolution.
            captureWidth = selectedResolution.width
            captureHeight = selectedResolution.height
        }

        // Adaptive quality: P2P gets full, loopback (ADB) gets medium-high, infrastructure gets capped
        let isP2P = pipelines[connectionId]?.isP2P ?? false
        let isLoopback = pipelines[connectionId]?.isLoopback ?? false
        var fps: Int
        let bitrate: Int
        let keyframeInterval: Double
        if isP2P {
            fps = 60  // AWDL can't sustain 120fps at typical bitrates; 60fps = 2x bits per frame
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
            // Infrastructure (WiFi router, Windows/Linux receivers)
            //
            // 30 FPS, and it looks *better* than 60 here, which is worth explaining.
            //
            // A frame must be sent within one frame interval or backpressure drops it.
            // At 60fps that window is 16.7ms, and ordinary Wi-Fi jitter misses it about
            // one time in six. Every dropped P-frame breaks the H.264 reference chain, so
            // each one forces a recovery keyframe — throttled, but still up to three a
            // second. The stream ends up mostly keyframes, inter-frame prediction stops
            // doing any work, and the picture goes soft exactly when it matters: faces,
            // scene changes, fast motion.
            //
            // At 30fps the window doubles to 33ms, sends land inside it, and the drops
            // stop. Measured on the same link and content: 60fps gave 25/67, 10/59, 6/64
            // drops with the bitrate being steered constantly; 30fps gave zero adaptive
            // events over 41 seconds and P-frames ranging 1.9-40KB against a 94KB
            // keyframe — proper temporal compression instead of a keyframe slideshow.
            //
            // A previous comment here claimed adaptive bitrate had made 60 safe by
            // softening quality instead of dropping frames. Measurement says otherwise:
            // the drops happen regardless of bitrate, so the softening *was* the damage.
            //
            // USB and P2P keep 60 — they have the headroom to make the deadline.
            // Users who want 60 here can still force it with the Frame Rate setting.
            fps = 30
            bitrate = selectedQuality.rawValue  // ceiling; adaptive bitrate steers the live rate
            keyframeInterval = 1.0  // Short interval bounds worst-case pixelation after a dropped P-frame
            LogManager.shared.log("Sender: Infrastructure mode — \(fps) FPS / \(bitrate / 1_000_000) Mbps / KF every 1s for \(serviceName)")
        }

        // User override from the Frame Rate setting (0 = Auto keeps the per-path value).
        if selectedFPS > 0 && selectedFPS != fps {
            fps = selectedFPS
            LogManager.shared.log("Sender: Frame rate override — \(fps) FPS (user setting)")
        }

        let hasReportedDims = pipelines[connectionId]?.reportedScreenWidth != nil
        // Apple's H.264 hardware encoders top out around 4096 pixels on the long edge;
        // a 5K session either fails to create or silently downscales. HEVC is specified
        // to 8K, so oversized pipelines are promoted rather than left to fail — which is
        // also why TargetBridge-class 5K streaming effectively requires HEVC.
        var resolvedCodec = codecFor(serviceName: serviceName)
        if resolvedCodec == .h264 && max(captureWidth, captureHeight) > 4096 {
            resolvedCodec = .hevc
            LogManager.shared.log("Sender: \(serviceName) at \(captureWidth)x\(captureHeight) exceeds H.264 encoder limits — using H.265")
        }
        LogManager.shared.log("Sender: Pipeline \(serviceName): \(captureWidth)x\(captureHeight)\(hasReportedDims ? " (device)" : "") @ \(selectedQuality.name) [\(fps) FPS, \(resolvedCodec.displayName), P2P: \(isP2P)]")

        // P2P: tight 0.1s rate limit window prevents AWDL buffer bloat.
        // Loopback (ADB tunnel): USB has ~280Mbps headroom — a tight window made VideoToolbox
        // silently drop frames during typing/cursor (changed frames briefly exceed the cap),
        // starving the Android decoder (its fixed ~16-frame hold turns low fps into multi-second
        // latency). Use a loose 1.0s window on USB so VT stops dropping. WiFi ADB is bandwidth-
        // limited so it keeps the tight 0.25s window.
        // Infrastructure: loose 1.0s window lets the encoder handle burst scenes naturally.
        let isWiFiADBPath = pipelines[connectionId]?.isWiFiADB ?? false
        let rateLimitWindow: Double = isP2P ? 0.1 : (isLoopback ? (isWiFiADBPath ? 0.25 : 1.0) : 1.0)
        let encoder = VideoEncoder(connectionId: connectionId, width: captureWidth, height: captureHeight, bitrate: bitrate, expectedFPS: fps, keyframeIntervalSeconds: keyframeInterval, rateLimitWindow: rateLimitWindow, codec: resolvedCodec)
        encoder.delegate = self
        // Per-receiver burst ceiling. Only ever loosened by explicit opt-in, so P2P and
        // every untouched connection keep the 1.5x behaviour they shipped with.
        if connectedDisplays.first(where: { $0.id == connectionId })?.smoothMotion == true {
            encoder.burstMultiplier = 3.0
        }
        pipelines[connectionId]?.videoEncoder = encoder
        // Seed adaptive bitrate: user-selected bitrate is the ceiling; start there.
        encoder.maxBitrate = bitrate // ceiling; encoder.currentBitrate already starts here

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
        recorder.useLegacyCapture = useLegacyCapture
        // Legacy capture (CGDisplayStream) doesn't support audio — disable it.
        recorder.captureAudio = audioEnabled && !useLegacyCapture
        recorder.audioEncoder = audioEnc
        pipelines[connectionId]?.screenRecorder = recorder

        Task {
            await recorder.startCapture()
        }
    }
    
    // VideoEncoderDelegate - Send to the specific connection that owns this encoder
    /// How many sends may be outstanding before we start dropping P-frames.
    ///
    /// Zero-tolerance backpressure corrupts the picture; unbounded queuing grows latency
    /// without limit. Two matches the depth SideScreen allows, and at ~33fps costs at most
    /// ~60ms of buffering in the worst case, against the 6-11ms we measure today.
    static let maxSendsInFlight = 2

    private var encodedFrameCount: Int = 0

    func videoEncoder(_ encoder: VideoEncoder, didEncode data: Data, for connectionId: UUID, isKeyframe: Bool) {
        guard let pipeline = pipelines[connectionId] else { return }

        encodedFrameCount += 1
        encoder.statsFrames += 1
        encoder.statsBytes += data.count
        if encodedFrameCount <= 3 || encodedFrameCount % 300 == 0 {
            LogManager.shared.log("Sender: Sending frame #\(encodedFrameCount) (\(data.count) bytes, KF: \(isKeyframe), pending: \(pipeline.pendingSends)) to \(pipeline.service.name)")
        }

        // Determine if this connection uses TCP framing (ADB/localhost always TCP, else follow global)
        let useTCP = pipeline.forceTCP || connectionType != "UDP"

        // TCP backpressure: skip P-frame if previous send still in flight.
        // NEVER drop keyframes — the decoder needs them to recover.
        // P2P / USB ADB: no backpressure (genuinely fat, reliable links).
        // Infrastructure and wireless ADB: completion-based backpressure.
        //
        // Wireless ADB has to be in this group even though its socket is on lo0. The adb
        // daemon relays every byte over Wi-Fi, so without backpressure the sender keeps
        // handing frames to a connection whose previous send is still in flight, adb's
        // buffers absorb them, and the phone sees the stream stall for seconds and then
        // burst — while its decoder sits idle at ~7ms dwell with an empty queue.
        let isInfra = !pipeline.isP2P && (!pipeline.isLoopback || pipeline.isWiFiADB) && useTCP
        if isInfra {
            // Feed the adaptive-bitrate controller (evaluated once/sec in the stats timer).
            // Counters live on the encoder (a class) — mutating them here, on the encoder
            // callback thread, must NOT touch the shared `pipelines` dictionary.
            encoder.adaptFrames += 1

            // Encoded frames are no longer dropped for ordinary congestion. Flow control
            // moved to BEFORE the encoder (VideoEncoder.encodeFrame gates on
            // sendsInFlight), where skipping a frame cannot break the reference chain —
            // that gate is why this path rarely sees more than two sends in flight now.
            // What remains here is a blackout guard only: when the radio stops completing
            // sends altogether (measured runs of 58/62 drops while time-slicing to AWDL),
            // queuing more encoded frames just buys seconds of latency, so beyond eight
            // in flight the frame is abandoned and a resync keyframe is requested. The
            // request throttle and the consecutive-drop cap prevent a keyframe storm.
            if !isKeyframe && encoder.sendsInFlight >= 8 {
                encoder.consecutiveDrops += 1
                if encoder.consecutiveDrops <= 3 {
                    encoder.forceKeyframe(silent: true)
                }
                encoder.adaptDrops += 1
                return
            }
            encoder.consecutiveDrops = 0
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

            // Mark send in progress for backpressure. ONLY the infrastructure path consumes
            // this. `pipelines` is owned by the main thread, but this delegate runs on
            // VideoToolbox's encoder-callback queue — mutating the dictionary here races with
            // the main thread and corrupts the heap (the v13 SIGSEGV crash). Writing it for
            // loopback/P2P was both pointless and the source of the crash, made far more likely
            // by the steady 62fps frame pump. Write it only for infra, and only on the main thread.
            if isInfra {
                // Synchronous, on this thread: the pre-encode gate reads it from the
                // capture path, so it cannot lag behind a main-queue hop.
                encoder.sendStarted()
                let nowNs = DispatchTime.now().uptimeNanoseconds
                DispatchQueue.main.async { [weak self] in
                    self?.pipelines[connectionId]?.pendingSends += 1
                    self?.pipelines[connectionId]?.sendInProgress = true
                    self?.pipelines[connectionId]?.lastSendTimeNs = nowNs
                }
            }

            pipeline.connection.send(content: packet, completion: .contentProcessed { [weak self] error in
                if isInfra {
                    encoder.sendFinished()
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self, var p = self.pipelines[connectionId] else { return }
                        p.pendingSends = max(0, p.pendingSends - 1)
                        p.sendInProgress = p.pendingSends > 0
                        self.pipelines[connectionId] = p
                    }
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

// MARK: - QR Pairing Sheet

/// Shows the ADB pairing QR. Android's own scanner reads it under
/// Developer options → Wireless debugging → Pair device with QR code.
struct QRPairingSheet: View {
    @ObservedObject var client: NetworkClient

    private func qrImage(from string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?
            .transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Pair over Wi-Fi")
                .font(.headline)

            if let payload = client.qrPairingPayload, let image = qrImage(from: payload) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 220, height: 220)
                    .padding(8)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
            } else {
                ProgressView().frame(width: 220, height: 220)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("On your Android phone:").fontWeight(.medium)
                Text("1. Settings → Developer options → Wireless debugging")
                Text("2. Turn it on, then tap “Pair device with QR code”")
                Text("3. Point that scanner at this code")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)

            // The payload begins with WIFI:, so the ordinary camera reads it as a
            // network to join and offers a Wi-Fi network that does not exist. Only
            // the Wireless debugging scanner understands the ADB type.
            Label("Don't use the normal Camera app — it will offer to join a Wi-Fi network that doesn't exist.",
                  systemImage: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !client.qrPairingStatus.isEmpty {
                Label(client.qrPairingStatus,
                      systemImage: client.qrPairingFailed ? "exclamationmark.triangle" : "clock")
                    .font(.caption)
                    .foregroundStyle(client.qrPairingFailed ? .orange : .secondary)
            }

            HStack {
                if client.qrPairingFailed {
                    Button("Try Again") { client.startQRPairing() }
                }
                Spacer()
                Button("Cancel") { client.cancelQRPairing() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}
