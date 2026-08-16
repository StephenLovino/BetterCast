#if canImport(UIKit)
import SwiftUI
import UIKit

@available(iOS 15.0, *)
struct SettingsView: View {
    @State var deviceName: String
    @State var aspectFill: Bool
    @State var cursorMode: Bool
    @State var audioEnabled: Bool

    let appVersion: String
    let buildNumber: String

    var onClose: () -> Void
    var onDeviceNameCommit: (String) -> Void
    var onAspectFillChange: (Bool) -> Void
    var onCursorModeChange: (Bool) -> Void
    var onAudioEnabledChange: (Bool) -> Void
    var onDisconnect: () -> Void
    var onShowSetupGuide: () -> Void
    var onHideSettingsButton: () -> Void
    var onAbout: () -> Void
    var onReportIssue: () -> Void

    @FocusState private var deviceNameFocused: Bool

    // Adaptive surface colors — follow system light/dark.
    private let background = Color(.systemBackground)
    private let onSurface = Color(.label)
    private let onSurfaceVariant = Color(.secondaryLabel)
    private let hairline = Color(.separator)
    private let fieldFill = Color(.secondarySystemBackground)
    // Fixed brand colors — same in light and dark.
    private let primaryContainer = Color(red: 0x4b/255.0, green: 0x8e/255.0, blue: 0xff/255.0)
    private let primaryFixedDim = Color(red: 0xad/255.0, green: 0xc6/255.0, blue: 0xff/255.0)
    private let secondaryFixedDim = Color(red: 0x2f/255.0, green: 0xd9/255.0, blue: 0xf4/255.0)
    private let accentOrange = Color(red: 0xef/255.0, green: 0x67/255.0, blue: 0x19/255.0)

    var body: some View {
        ZStack {
            background.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {
                    header
                    deviceSection
                    displaySection
                    inputSection
                    audioSection
                    connectionSection
                    helpSection
                    advancedSection
                    footer
                    Color.clear.frame(height: 24)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }
        }
        .onTapGesture { deviceNameFocused = false }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(primaryContainer)
                Text("BetterCast")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(onSurface)
                Spacer()
            }
            .frame(height: 56)

            Text("Settings")
                .font(.system(size: 32, weight: .bold))
                .tracking(-0.5)
                .foregroundColor(onSurface)
            Text("Configure how this device receives streams and interacts with your Mac.")
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Sections

    private var deviceSection: some View {
        section(title: "DEVICE", icon: "iphone") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Device Name")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(onSurfaceVariant)
                TextField("", text: $deviceName)
                    .focused($deviceNameFocused)
                    .submitLabel(.done)
                    .onSubmit { commitDeviceName() }
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled(true)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(onSurface)
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(fieldFill)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(deviceNameFocused ? primaryContainer.opacity(0.6) : hairline, lineWidth: 1)
                            )
                    )
                Text("Restart the app to advertise the new name on the network.")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(onSurfaceVariant.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }
    }

    private var displaySection: some View {
        section(title: "DISPLAY", icon: "rectangle.on.rectangle") {
            VStack(spacing: 0) {
                segmentedRow(
                    icon: "aspectratio",
                    iconColor: primaryFixedDim,
                    title: "Aspect",
                    description: "How the Mac display fits this screen.",
                    selection: Binding(
                        get: { aspectFill ? 0 : 1 },
                        set: { newValue in
                            let fill = (newValue == 0)
                            aspectFill = fill
                            onAspectFillChange(fill)
                        }
                    ),
                    options: ["Fill", "Fit"]
                )
            }
            .padding(16)
        }
    }

    private var inputSection: some View {
        section(title: "INPUT", icon: "hand.tap") {
            VStack(spacing: 0) {
                segmentedRow(
                    icon: "cursorarrow.motionlines",
                    iconColor: secondaryFixedDim,
                    title: "Mode",
                    description: "Touch maps taps directly. Cursor moves a trackpad-style pointer.",
                    selection: Binding(
                        get: { cursorMode ? 1 : 0 },
                        set: { newValue in
                            let isCursor = (newValue == 1)
                            cursorMode = isCursor
                            onCursorModeChange(isCursor)
                        }
                    ),
                    options: ["Touch", "Cursor"]
                )
            }
            .padding(16)
        }
    }

    private var audioSection: some View {
        section(title: "AUDIO", icon: "speaker.wave.2") {
            VStack(spacing: 0) {
                toggleRow(
                    icon: "speaker.wave.2.fill",
                    iconColor: primaryFixedDim,
                    title: "Enable Audio",
                    description: "Stream Mac audio to this device. Toggling reconnects the stream.",
                    isOn: Binding(
                        get: { audioEnabled },
                        set: { newValue in
                            audioEnabled = newValue
                            onAudioEnabledChange(newValue)
                        }
                    )
                )
            }
            .padding(16)
        }
    }

    private var connectionSection: some View {
        section(title: "CONNECTION", icon: "antenna.radiowaves.left.and.right") {
            VStack(spacing: 0) {
                disclosureRow(
                    icon: "xmark.circle.fill",
                    iconColor: accentOrange,
                    title: "Disconnect",
                    subtitle: "End the current stream and return to the sender list.",
                    action: {
                        onDisconnect()
                        onClose()
                    }
                )
            }
            .padding(.vertical, 8)
        }
    }

    private var helpSection: some View {
        section(title: "HELP", icon: "questionmark.circle") {
            VStack(spacing: 0) {
                disclosureRow(
                    icon: "questionmark.circle.fill",
                    iconColor: primaryFixedDim,
                    title: "Setup Guide",
                    subtitle: "Walk through pairing and streaming.",
                    action: onShowSetupGuide
                )
                divider
                disclosureRow(
                    icon: "info.circle.fill",
                    iconColor: secondaryFixedDim,
                    title: "About BetterCast",
                    subtitle: "bettercast.online",
                    action: onAbout
                )
                divider
                disclosureRow(
                    icon: "exclamationmark.bubble.fill",
                    iconColor: accentOrange,
                    title: "Report an Issue",
                    subtitle: "Send feedback on GitHub.",
                    action: onReportIssue
                )
            }
            .padding(.vertical, 8)
        }
    }

    private var advancedSection: some View {
        section(title: "ADVANCED", icon: "wrench.and.screwdriver") {
            VStack(spacing: 0) {
                disclosureRow(
                    icon: "eye.slash.fill",
                    iconColor: accentOrange,
                    title: "Hide Settings Button",
                    subtitle: "Three-finger tap anywhere brings it back.",
                    action: {
                        onHideSettingsButton()
                        onClose()
                    }
                )
            }
            .padding(.vertical, 8)
        }
    }

    private var footer: some View {
        VStack(spacing: 4) {
            Text("BetterCast Receiver")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .tracking(0.6)
                .foregroundColor(onSurfaceVariant)
            Text("VERSION \(appVersion) (BUILD \(buildNumber))")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .tracking(0.6)
                .foregroundColor(onSurfaceVariant.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    // MARK: - Reusable bits

    private var divider: some View {
        Rectangle()
            .fill(hairline)
            .frame(height: 1)
            .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func section<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
            }
            .foregroundColor(onSurfaceVariant)
            .padding(.leading, 6)

            glassCard(cornerRadius: 20) {
                content()
            }
        }
    }

    private func disclosureRow(icon: String, iconColor: Color, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(iconColor.opacity(0.15))
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(iconColor)
                }
                .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(onSurface)
                    Text(subtitle)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(onSurfaceVariant.opacity(0.6))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggleRow(icon: String, iconColor: Color, title: String, description: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(iconColor.opacity(0.15))
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(iconColor)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(onSurface)
                Text(description)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(primaryContainer)
        }
    }

    private func segmentedRow(icon: String, iconColor: Color, title: String, description: String, selection: Binding<Int>, options: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(iconColor.opacity(0.15))
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(iconColor)
                }
                .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(onSurface)
                    Text(description)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            Picker("", selection: selection) {
                ForEach(0..<options.count, id: \.self) { idx in
                    Text(options[idx]).tag(idx)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    @ViewBuilder
    private func glassCard<Content: View>(cornerRadius: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        content()
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(hairline, lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.2), radius: 16, y: 8)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private func commitDeviceName() {
        deviceNameFocused = false
        let trimmed = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        deviceName = trimmed
        onDeviceNameCommit(trimmed)
    }
}

@available(iOS 15.0, *)
final class SettingsHostingController: UIHostingController<SettingsView> {
    private weak var connect: ViewController?
    private let appVersion: String
    private let buildNumber: String

    init(connect: ViewController) {
        self.connect = connect
        let info = Bundle.main.infoDictionary ?? [:]
        self.appVersion = info["CFBundleShortVersionString"] as? String ?? "?"
        self.buildNumber = info["CFBundleVersion"] as? String ?? "?"

        super.init(rootView: SettingsHostingController.makeRootView(
            connect: connect,
            appVersion: self.appVersion,
            buildNumber: self.buildNumber,
            host: nil
        ))

        rootView = SettingsHostingController.makeRootView(
            connect: connect,
            appVersion: appVersion,
            buildNumber: buildNumber,
            host: self
        )
    }

    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Rebuild `rootView` with state pulled fresh from the Connect VC. Called
    /// by `BCTabBarController` whenever this tab is selected so values stay in
    /// sync with the in-stream gear overlay.
    func refreshFromConnect() {
        guard let connect = connect else { return }
        rootView = SettingsHostingController.makeRootView(
            connect: connect,
            appVersion: appVersion,
            buildNumber: buildNumber,
            host: self
        )
    }

    private static func makeRootView(
        connect: ViewController,
        appVersion: String,
        buildNumber: String,
        host: SettingsHostingController?
    ) -> SettingsView {
        let switchToConnect: () -> Void = { [weak host] in
            host?.tabBarController?.selectedIndex = 0
        }
        let switchToSetup: () -> Void = { [weak host] in
            host?.tabBarController?.selectedIndex = 1
        }
        let about: () -> Void = {
            if let url = URL(string: "https://bettercast.online") {
                UIApplication.shared.open(url)
            }
        }
        let report: () -> Void = {
            if let url = URL(string: "https://github.com/StephenLovino/BetterCast/issues") {
                UIApplication.shared.open(url)
            }
        }
        return SettingsView(
            deviceName: connect.currentDeviceName,
            aspectFill: connect.currentAspectFill,
            cursorMode: connect.currentCursorMode,
            audioEnabled: connect.currentAudioEnabled,
            appVersion: appVersion,
            buildNumber: buildNumber,
            onClose: switchToConnect,
            onDeviceNameCommit: { [weak connect] name in connect?.commitDeviceName(name) },
            onAspectFillChange: { [weak connect] fill in connect?.applyAspectFill(fill) },
            onCursorModeChange: { [weak connect] cursor in connect?.applyCursorMode(cursor) },
            onAudioEnabledChange: { [weak connect] enabled in connect?.applyAudioEnabled(enabled) },
            onDisconnect: { [weak connect] in connect?.disconnectAndRestore() },
            onShowSetupGuide: switchToSetup,
            onHideSettingsButton: { [weak connect] in connect?.hideSettingsButtonFromSibling() },
            onAbout: about,
            onReportIssue: report
        )
    }
}
#endif
