import SwiftUI

/**
 Launch-time nudge asking people to chip in.

 BetterCast is free and unlicensed, so there is nothing to check against: whether
 somebody donated is not knowable from inside the app. "Stop asking" is therefore an
 honour-system button, not a verified state — anyone can press it. That is the intended
 trade. The alternative is a licence server and key entry, which is a lot of machinery
 (and a support burden) to protect a voluntary donation.

 The prompt is deliberately not shown on the very first launch. A brand-new user has not
 seen the app work yet, and asking before delivering anything is how you get uninstalled
 rather than paid.
 */
struct DonatePromptState {
    /// Set only by the "I already donated" button. Never cleared by the app.
    @AppStorage("donatePromptSilenced") static var silenced = false

    /// Counts launches so the first one can pass unbothered.
    @AppStorage("donatePromptLaunchCount") static var launchCount = 0

    /// Call once per launch. Returns whether the prompt should be presented.
    static func shouldPresentOnLaunch() -> Bool {
        launchCount += 1
        guard !silenced else { return false }
        return launchCount > 1
    }
}

struct DonatePromptView: View {
    /// Dismisses for this launch only.
    var onLater: () -> Void
    /// Dismisses for good.
    var onAlreadyDonated: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "cup.and.saucer.fill")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
                .padding(.top, 6)

            Text(tr("Want me to keep building free stuff?"))
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)

            Text(tr("BetterCast is free, has no ads, and does not track you. If it saved you the price of a second monitor, a coffee goes a long way."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 8) {
                Button {
                    if let url = URL(string: BCConstants.donateURL) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label(tr("Buy me a coffee"), systemImage: "heart.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)

                Button(tr("Maybe later")) { onLater() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .keyboardShortcut(.cancelAction)
            }

            Button(tr("I already donated — stop asking")) { onAlreadyDonated() }
                .buttonStyle(.link)
                .font(.caption)
                .padding(.bottom, 4)
        }
        .padding(24)
        .frame(width: 380)
    }
}
