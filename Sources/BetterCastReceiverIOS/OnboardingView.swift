#if canImport(UIKit)
import SwiftUI
import UIKit

@available(iOS 15.0, *)
struct OnboardingView: View {
    var onGetStarted: () -> Void
    var onLearnMore: () -> Void
    var onSettings: () -> Void

    private let background = Color(red: 0x13/255.0, green: 0x13/255.0, blue: 0x14/255.0)
    private let onSurface = Color(red: 0xe5/255.0, green: 0xe2/255.0, blue: 0xe3/255.0)
    private let onSurfaceVariant = Color(red: 0xc1/255.0, green: 0xc6/255.0, blue: 0xd7/255.0)
    private let primaryContainer = Color(red: 0x4b/255.0, green: 0x8e/255.0, blue: 0xff/255.0)
    private let primaryFixedDim = Color(red: 0xad/255.0, green: 0xc6/255.0, blue: 0xff/255.0)
    private let secondary = Color(red: 0x5d/255.0, green: 0xe6/255.0, blue: 0xff/255.0)
    private let secondaryFixedDim = Color(red: 0x2f/255.0, green: 0xd9/255.0, blue: 0xf4/255.0)
    private let accentGold = Color(red: 1.0, green: 0xd6/255.0, blue: 0x0a/255.0)
    private let statusSuccess = Color(red: 0x32/255.0, green: 0xd7/255.0, blue: 0x4b/255.0)

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
                VStack(spacing: 32) {
                    header
                    heroCard
                    headlines
                    statGrid
                    ctas
                    Color.clear.frame(height: 24)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }

            VStack {
                Spacer()
                bottomNav
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "play.display")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(primaryContainer)
                Text("BetterCast")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(onSurface)
            }
            Spacer()
            Button(action: onSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundColor(onSurface)
            }
        }
        .frame(height: 56)
    }

    private var heroCard: some View {
        ZStack {
            primaryContainer.opacity(0.18)
                .blur(radius: 80)
                .frame(maxWidth: 260, maxHeight: 260)

            glassCard(cornerRadius: 32) {
                ZStack {
                    if let icon = UIImage(named: "AppIcon") {
                        Image(uiImage: icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .cornerRadius(24)
                            .padding(24)
                    } else {
                        Image(systemName: "display.2")
                            .font(.system(size: 80, weight: .light))
                            .foregroundColor(primaryFixedDim)
                    }
                }
            }
            .frame(maxWidth: 260)
            .aspectRatio(1, contentMode: .fit)
        }
    }

    private var headlines: some View {
        VStack(spacing: 12) {
            Text("Turn your device into a second display. For free.")
                .font(.system(size: 28, weight: .bold))
                .tracking(-0.5)
                .foregroundColor(onSurface)
                .multilineTextAlignment(.center)
            Text("Wireless hardware-level integration with zero setup.")
                .font(.system(size: 16, weight: .regular))
                .foregroundColor(onSurfaceVariant)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 360)
    }

    private var statGrid: some View {
        VStack(spacing: 16) {
            HStack(spacing: 16) {
                statCardSmall(
                    icon: "speedometer",
                    badge: "ULTRA LOW",
                    value: "0.02ms",
                    label: "Latency",
                    iconColor: secondaryFixedDim
                )
                statCardSmall(
                    icon: "waveform.path.ecg",
                    badge: "SMOOTH",
                    value: "60 FPS",
                    label: "Frame Rate",
                    iconColor: secondaryFixedDim
                )
            }
            statCardWide
        }
        .frame(maxWidth: 420)
    }

    private func statCardSmall(icon: String, badge: String, value: String, label: String, iconColor: Color) -> some View {
        glassCard(cornerRadius: 20) {
            VStack(alignment: .leading) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundColor(iconColor)
                Spacer(minLength: 12)
                VStack(alignment: .leading, spacing: 4) {
                    Text(badge)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .tracking(0.6)
                        .foregroundColor(secondaryFixedDim)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(secondary.opacity(0.15))
                        .clipShape(Capsule())
                    Text(value)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(onSurface)
                        .shadow(color: Color(red: 0, green: 0x7a/255.0, blue: 1.0).opacity(0.6), radius: 10)
                    Text(label)
                        .font(.system(size: 12, weight: .medium))
                        .tracking(0.6)
                        .foregroundColor(onSurfaceVariant)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private var statCardWide: some View {
        glassCard(cornerRadius: 20) {
            HStack {
                HStack(spacing: 14) {
                    Image(systemName: "4k.tv")
                        .font(.system(size: 24, weight: .regular))
                        .foregroundColor(accentGold)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("4K Ultra HD")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(onSurface)
                        Text("Crystal clear resolution")
                            .font(.system(size: 12, weight: .medium))
                            .tracking(0.6)
                            .foregroundColor(onSurfaceVariant)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 8))
                        .foregroundColor(statusSuccess)
                    Text("NATIVE")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .tracking(0.6)
                        .foregroundColor(statusSuccess)
                }
            }
            .padding(16)
        }
    }

    private var ctas: some View {
        VStack(spacing: 10) {
            Button(action: onGetStarted) {
                Text("Get Started")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(liquidGradient)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .shadow(color: primaryContainer.opacity(0.3), radius: 16, y: 6)
            }
            Button(action: onLearnMore) {
                Text("Learn More")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(primaryFixedDim)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .overlay(
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
                            )
                    )
            }
        }
        .frame(maxWidth: 420)
    }

    private var bottomNav: some View {
        HStack {
            navItem(icon: "play.display", title: "Connect", active: true) { onGetStarted() }
            navItem(icon: "questionmark.circle", title: "Setup", active: false) {}
            navItem(icon: "slider.horizontal.3", title: "Settings", active: false) { onSettings() }
            navItem(icon: "info.circle", title: "About", active: false) {}
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 28)
        .background(.ultraThinMaterial)
        .overlay(
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1),
            alignment: .top
        )
    }

    private func navItem(icon: String, title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: active ? .semibold : .regular))
                Text(title)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .tracking(0.6)
            }
            .foregroundColor(active ? primaryContainer : onSurfaceVariant)
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
                            .fill(Color.white.opacity(0.03))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.37), radius: 16, y: 8)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

@available(iOS 15.0, *)
final class OnboardingHostingController: UIHostingController<OnboardingView> {
    static let completionKey = "hasCompletedOnboarding"

    init(onComplete: @escaping () -> Void) {
        let dismissAndComplete: () -> Void = {
            UserDefaults.standard.set(true, forKey: OnboardingHostingController.completionKey)
            onComplete()
        }
        super.init(rootView: OnboardingView(
            onGetStarted: dismissAndComplete,
            onLearnMore: {
                if let url = URL(string: "https://bettercast.online") {
                    UIApplication.shared.open(url)
                }
            },
            onSettings: dismissAndComplete
        ))
        overrideUserInterfaceStyle = .dark
    }

    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
#endif
