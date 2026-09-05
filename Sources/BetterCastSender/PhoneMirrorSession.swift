import Foundation
import SwiftUI
import CoreMedia

/// Puts a cable-attached phone's screen in a window on this Mac.
///
/// Deliberately built from parts that already exist: `PhoneCapture` produces
/// `CMSampleBuffer`s, which is exactly what `ReceiverVideoRenderer` renders and what
/// `ReceiverWindowController` already knows how to put on screen. The only new idea
/// here is where the frames come from.
final class PhoneMirrorSession: ObservableObject {
    static let shared = PhoneMirrorSession()

    let capture = PhoneCapture()

    private let renderer = ReceiverVideoRenderer()
    private let windowController = ReceiverWindowController()

    @Published private(set) var activeDeviceName: String?

    /// Last frame size seen, so the window is only resized when the shape actually
    /// changes rather than on every frame.
    private var lastSize: CGSize = .zero

    private init() {
        capture.onSampleBuffer = { [weak self] sample in
            // Frames arrive on the capture queue; the renderer wants the main thread.
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.renderer.enqueue(sample)
                self.matchWindowToFrame(sample)
            }
        }
    }

    /// Shape the window to the phone rather than leaving it at whatever the receive
    /// window last was. A portrait phone in a landscape window is mostly black bars,
    /// and the phone can rotate mid-session, so this follows it.
    private func matchWindowToFrame(_ sample: CMSampleBuffer) {
        guard let px = CMSampleBufferGetImageBuffer(sample) else { return }
        let size = CGSize(width: CVPixelBufferGetWidth(px), height: CVPixelBufferGetHeight(px))
        guard size.width > 0, size.height > 0, size != lastSize else { return }
        lastSize = size
        windowController.resizeToFitVideo(size)
    }

    func startWatching() { capture.startWatching() }

    func show(_ device: PhoneCapture.Device) {
        windowController.open(renderer: renderer)
        capture.start(device: device)
        activeDeviceName = device.name
    }

    func stop() {
        capture.stop()
        activeDeviceName = nil
        lastSize = .zero
    }
}
