import Foundation
import AVFoundation
import CoreMediaIO
import Combine

/// Shows the screen of an iPhone or iPad attached by cable.
///
/// macOS publishes a connected iOS device's screen as an ordinary capture device,
/// which is how QuickTime records a phone. Nothing is installed on the phone and
/// no app runs there: the Mac does the capturing. That makes this far smaller than
/// the ReplayKit broadcast extension it first appeared to need, and it sidesteps
/// that route's memory ceiling entirely.
///
/// Three things are easy to get wrong here, and each cost an afternoon:
///
/// - The device is invisible until `kCMIOHardwarePropertyAllowScreenCaptureDevices`
///   is set. It is off by default.
/// - A typed `AVCaptureDevice.DiscoverySession` never returns it, because it is not
///   a camera type. Only the deprecated flat list does.
/// - macOS treats it as a **camera** for permissions. Without camera access the
///   session starts, delivers nothing, and the device then disappears from the list
///   entirely, which looks like broken hardware rather than a denied prompt.
final class PhoneCapture: NSObject, ObservableObject {

    struct Device: Identifiable, Hashable {
        let id: String          // AVCaptureDevice.uniqueID
        let name: String
    }

    @Published private(set) var devices: [Device] = []
    @Published private(set) var isCapturing = false
    @Published private(set) var status: String = ""

    /// Frames from the phone, in the same currency the receiver window already
    /// renders and the encoder already accepts.
    var onSampleBuffer: ((CMSampleBuffer) -> Void)?

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    /// The device is muxed: one input carries both picture and sound. Without an
    /// audio output attached the sound is simply discarded, which is why the phone
    /// played silently while the picture worked.
    private let audioPreview = AVCaptureAudioPreviewOutput()
    private let queue = DispatchQueue(label: "com.bettercast.phonecapture")
    private var refreshTimer: Timer?

    override init() {
        super.init()
        PhoneCapture.allowScreenCaptureDevices()
        output.setSampleBufferDelegate(self, queue: queue)
    }

    /// Publish iOS screens to AVFoundation. Off by default; nothing sees the device
    /// until this is set, and it must be set before enumerating.
    private static func allowScreenCaptureDevices() {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var allow: UInt32 = 1
        CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil,
                                  UInt32(MemoryLayout<UInt32>.size), &allow)
    }

    /// Watch for phones being plugged and unplugged.
    func startWatching() {
        guard refreshTimer == nil else { return }
        refresh()
        let t = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t
    }

    func stopWatching() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func refresh() {
        // The flat list is deprecated and is also the only thing that returns an iOS
        // screen: it is muxed rather than video, so every typed discovery session
        // filters it out.
        let found = AVCaptureDevice.devices()
            .filter { $0.modelID == "iOS Device" }
            .map { Device(id: $0.uniqueID, name: $0.localizedName) }

        guard found != devices else { return }
        for d in found where !devices.contains(d) {
            LogManager.shared.log("Phone: \(d.name) attached by cable")
        }
        for d in devices where !found.contains(d) {
            LogManager.shared.log("Phone: \(d.name) detached")
            if isCapturing { stop() }
        }
        devices = found
    }

    // MARK: - Capture

    func start(device: Device) {
        guard !isCapturing else { return }

        requestCameraAccess { [weak self] granted in
            guard let self = self else { return }
            guard granted else {
                self.status = "Camera access is needed to show a phone's screen"
                LogManager.shared.log("Phone: camera access denied — macOS treats a phone's screen as a camera, so this permission gates it")
                return
            }
            self.beginSession(deviceID: device.id, name: device.name)
        }
    }

    /// The permission is genuinely for a camera as far as macOS is concerned, so the
    /// prompt says "camera" even though what is being read is a phone's screen.
    private func requestCameraAccess(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            done(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                guard ok else { DispatchQueue.main.async { done(false) }; return }
                // Sound is a separate permission. Video is what gates the feature, so
                // a refusal here costs the audio and not the picture.
                AVCaptureDevice.requestAccess(for: .audio) { _ in
                    DispatchQueue.main.async { done(true) }
                }
            }
        default:
            done(false)
        }
    }

    private func beginSession(deviceID: String, name: String) {
        // Re-read the device: a denied permission earlier in the process can leave a
        // stale entry that no longer resolves.
        guard let dev = AVCaptureDevice.devices().first(where: { $0.uniqueID == deviceID }) else {
            status = "\(name) is no longer available"
            return
        }

        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        do {
            let input = try AVCaptureDeviceInput(device: dev)
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                status = "Could not read \(name)"
                return
            }
            session.addInput(input)
        } catch {
            session.commitConfiguration()
            status = error.localizedDescription
            LogManager.shared.log("Phone: could not open \(name) — \(error.localizedDescription)")
            return
        }

        if !session.outputs.contains(output), session.canAddOutput(output) {
            session.addOutput(output)
        }
        // Play the phone's audio through this Mac's current output device. Volume 1.0
        // is the phone's own level, so the phone's volume buttons still govern it.
        if !session.outputs.contains(audioPreview), session.canAddOutput(audioPreview) {
            audioPreview.volume = 1.0
            session.addOutput(audioPreview)
        }
        session.commitConfiguration()

        queue.async { [weak self] in
            self?.session.startRunning()
            DispatchQueue.main.async {
                self?.isCapturing = true
                self?.status = "Showing \(name)"
                LogManager.shared.log("Phone: capturing \(name) over the cable")
            }
        }
    }

    func stop() {
        guard isCapturing else { return }
        queue.async { [weak self] in
            self?.session.stopRunning()
            DispatchQueue.main.async {
                self?.isCapturing = false
                self?.status = ""
                LogManager.shared.log("Phone: stopped capturing")
            }
        }
    }
}

extension PhoneCapture: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        onSampleBuffer?(sampleBuffer)
    }
}
