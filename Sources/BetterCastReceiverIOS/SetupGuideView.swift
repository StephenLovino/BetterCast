#if canImport(UIKit)
import SwiftUI
import UIKit

@available(iOS 15.0, *)
struct SetupGuideView: View {
    var onDownloadMac: () -> Void
    var onStartDiscovery: () -> Void

    // Adaptive surface colors — follow system light/dark.
    private let background = Color(.systemBackground)
    private let onSurface = Color(.label)
    private let onSurfaceVariant = Color(.secondaryLabel)
    private let hairline = Color(.separator)
    // Fixed brand colors — same in light and dark.
    private let primaryContainer = Color(red: 0x4b/255.0, green: 0x8e/255.0, blue: 0xff/255.0)
    private let primaryFixedDim = Color(red: 0xad/255.0, green: 0xc6/255.0, blue: 0xff/255.0)
    private let secondaryFixedDim = Color(red: 0x2f/255.0, green: 0xd9/255.0, blue: 0xf4/255.0)
    private let statusSuccess = Color(red: 0x32/255.0, green: 0xd7/255.0, blue: 0x4b/255.0)
    private let accentOrange = Color(red: 0xef/255.0, green: 0x67/255.0, blue: 0x19/255.0)

    private let liquidGradient = LinearGradient(
        colors: [
            Color(red: 0x00/255.0, green: 0x7a/255.0, blue: 1.0),
            Color(red: 0x5d/255.0, green: 0xe6/255.0, blue: 1.0)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    var body: some View {
        ZStack {
            background.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    header
                    stepCards
                    statsRow
                    Color.clear.frame(height: 24)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "play.display")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(primaryContainer)
                Text("BetterCast")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(onSurface)
                Spacer()
            }
            .frame(height: 56)

            Text("Setup Guide")
                .font(.system(size: 32, weight: .bold))
                .tracking(-0.5)
                .foregroundColor(onSurface)
            Text("Follow these steps to synchronize your workspace and start high-performance casting.")
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Step Cards

    private var stepCards: some View {
        VStack(spacing: 16) {
            stepCard(
                icon: "desktopcomputer",
                iconColor: primaryFixedDim,
                title: "Install on Mac",
                description: "Download and install the BetterCast Sender app on your macOS device to begin streaming.",
                badge: .init(text: "REQUIRED", color: accentOrange),
                action: .init(title: "Download for Mac", icon: "arrow.down.circle.fill", onTap: onDownloadMac)
            )
            stepCard(
                icon: "checkmark.shield.fill",
                iconColor: statusSuccess,
                title: "Install Receiver",
                description: "You're already here! This device is configured as the primary receiver for your stream.",
                badge: .init(text: "COMPLETED", color: statusSuccess),
                action: nil
            )
            stepCard(
                icon: "wifi",
                iconColor: secondaryFixedDim,
                title: "Same Network",
                description: "Ensure both devices are on the same Wi-Fi network. Wired USB-C is also supported for sub-0.02ms latency.",
                badge: .init(text: "Wi-Fi · OFFICIAL_AC", color: secondaryFixedDim, monospaced: true),
                action: nil
            )
            stepCard(
                icon: "dot.radiowaves.left.and.right",
                iconColor: primaryFixedDim,
                title: "Go Live",
                description: "Once both apps are running, they will discover each other automatically. Or, start manually below.",
                badge: nil,
                action: .init(title: "Start Automatic Discovery", icon: "sparkles", onTap: onStartDiscovery)
            )
        }
    }

    private struct Badge {
        let text: String
        let color: Color
        var monospaced: Bool = false
    }

    private struct CardAction {
        let title: String
        let icon: String
        let onTap: () -> Void
    }

    @ViewBuilder
    private func stepCard(icon: String, iconColor: Color, title: String, description: String, badge: Badge?, action: CardAction?) -> some View {
        glassCard(cornerRadius: 20) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(iconColor.opacity(0.15))
                        Image(systemName: icon)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(iconColor)
                    }
                    .frame(width: 48, height: 48)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(title)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(onSurface)
                        Text(description)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundColor(onSurfaceVariant)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if let badge = badge {
                        Text(badge.text)
                            .font(.system(size: 9, weight: .semibold, design: badge.monospaced ? .monospaced : .default))
                            .tracking(0.6)
                            .foregroundColor(badge.color)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(badge.color.opacity(0.15))
                            .clipShape(Capsule())
                            .fixedSize()
                    }
                }

                if let action = action {
                    Button(action: action.onTap) {
                        HStack(spacing: 8) {
                            Image(systemName: action.icon)
                                .font(.system(size: 15, weight: .semibold))
                            Text(action.title)
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(liquidGradient)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .shadow(color: primaryContainer.opacity(0.3), radius: 12, y: 4)
                    }
                }
            }
            .padding(16)
        }
    }

    // MARK: - Stats Row

    private var statsRow: some View {
        HStack(spacing: 16) {
            statChip(label: "LATENCY", value: "0.02ms", color: primaryFixedDim)
            statChip(label: "REFRESH", value: "60 FPS", color: secondaryFixedDim)
        }
    }

    private func statChip(label: String, value: String, color: Color) -> some View {
        glassCard(cornerRadius: 16) {
            VStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .tracking(0.6)
                    .foregroundColor(onSurfaceVariant)
                Text(value)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(color)
            }
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
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
}

@available(iOS 15.0, *)
final class SetupGuideHostingController: UIHostingController<SetupGuideView> {

    init() {
        let openDownload: () -> Void = {
            if let url = URL(string: "https://bettercast.online/#install") {
                UIApplication.shared.open(url)
            }
        }
        weak var weakSelf: SetupGuideHostingController?
        let startDiscovery: () -> Void = {
            weakSelf?.tabBarController?.selectedIndex = 0
        }
        super.init(rootView: SetupGuideView(
            onDownloadMac: openDownload,
            onStartDiscovery: startDiscovery
        ))
        weakSelf = self
    }

    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
#endif
