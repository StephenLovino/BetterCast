import SwiftUI

/// Asks whether a device that dialled this Mac may use it as a display.
///
/// The invite listener accepts anything that can reach the port, so without this the
/// first the user knew about a request was a new virtual display appearing. Extend
/// mode means the caller would have got a blank desktop, but in mirror mode it would
/// have been the real screen, and either way it should be the user's call.
struct InvitePromptView: View {
    /// Address the request came from. Shown as-is: there is nothing to verify it
    /// against yet, so it is a hint, not proof of who is calling.
    let deviceName: String
    var onAllowOnce: () -> Void
    var onAllowAlways: () -> Void
    var onDeny: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "display.and.arrow.down")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
                .padding(.top, 6)

            Text(tr("Let this device use your screen?"))
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)

            Text(deviceName)
                .font(.system(.callout, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))

            Text(tr("It asked to use this Mac as a display. Allow it only if you recognise it."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 8) {
                Button(tr("Don't allow")) { onDeny() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .keyboardShortcut(.defaultAction)

                Button(tr("Allow once")) { onAllowOnce() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
            }

            Button(tr("Always allow this device")) { onAllowAlways() }
                .buttonStyle(.link)
                .font(.caption)
                .padding(.bottom, 4)
        }
        .padding(24)
        .frame(width: 380)
    }
}
