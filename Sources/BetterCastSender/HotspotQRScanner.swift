import SwiftUI
import AVFoundation
import Vision

/// Reads a Wi-Fi QR shown on the phone so hotspot credentials never have to be typed.
///
/// The credentials can only travel phone → Mac: `startLocalOnlyHotspot` generates the
/// SSID and passphrase itself and regenerates them on every start, so a code displayed
/// on the Mac could never describe them. That leaves the Mac reading the phone's screen.
///
/// Detection runs through Vision rather than `AVCaptureMetadataOutput`. That output
/// only reports faces on macOS — the barcode types exist in the API because it is
/// shared with iOS, but `.qr` never appears in `availableMetadataObjectTypes`, and
/// assigning it throws. Vision's barcode request works properly here.
final class HotspotQRScanner: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    /// Parsed credentials, published once a valid Wi-Fi QR is seen.
    @Published var result: (ssid: String, password: String)?
    @Published var errorMessage: String?
    @Published var isRunning = false

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "bettercast.qrscanner")

    func start() {
        guard !isRunning else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.configureAndRun() }
                    else { self?.errorMessage = "Camera access denied." }
                }
            }
        default:
            errorMessage = "Camera access denied. Enable it in System Settings → Privacy & Security → Camera."
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self = self, self.session.isRunning else { return }
            self.session.stopRunning()
            DispatchQueue.main.async { self.isRunning = false }
        }
    }

    private func configureAndRun() {
        guard let device = AVCaptureDevice.default(for: .video) else {
            errorMessage = "No camera found on this Mac."
            return
        }
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }

        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            session.commitConfiguration()
            errorMessage = "Could not open the camera."
            return
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            errorMessage = "Could not start the camera feed."
            return
        }
        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: queue)
        session.commitConfiguration()

        queue.async { [weak self] in
            guard let self = self else { return }
            self.session.startRunning()
            DispatchQueue.main.async { self.isRunning = true }
        }
    }

    /// Only look at every few frames — a QR held up to the camera lingers for many
    /// frames, and running Vision on all of them just burns CPU.
    private var frameCounter = 0

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        frameCounter += 1
        guard frameCounter % 4 == 0,
              result == nil,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let request = VNDetectBarcodesRequest { [weak self] request, _ in
            guard let self = self else { return }
            let payloads = (request.results as? [VNBarcodeObservation])?
                .compactMap { $0.payloadStringValue } ?? []
            guard let parsed = payloads.lazy.compactMap(Self.parseWiFiQR).first else { return }

            DispatchQueue.main.async {
                guard self.result == nil else { return }
                self.result = parsed
                LogManager.shared.log("Hotspot QR: Read network '\(parsed.ssid)'")
                self.stop()
            }
        }
        request.symbologies = [.qr]
        try? VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:]).perform([request])
    }

    /// Parse the standard Wi-Fi QR format, e.g. `WIFI:S:MyNet;T:WPA;P:secret;;`.
    ///
    /// Fields may appear in any order, and `;` or `:` inside a value are backslash
    /// escaped by the spec, so unescape before returning.
    static func parseWiFiQR(_ raw: String) -> (ssid: String, password: String)? {
        guard raw.uppercased().hasPrefix("WIFI:") else { return nil }
        let body = String(raw.dropFirst("WIFI:".count))

        var fields: [String: String] = [:]
        var current = ""
        var parts: [String] = []
        var escaped = false
        for ch in body {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if ch == ";" { parts.append(current); current = ""; continue }
            current.append(ch)
        }
        if !current.isEmpty { parts.append(current) }

        for part in parts {
            guard let sep = part.firstIndex(of: ":") else { continue }
            let key = String(part[part.startIndex..<sep]).uppercased()
            let value = String(part[part.index(after: sep)...])
            fields[key] = value
        }

        guard let ssid = fields["S"], !ssid.isEmpty else { return nil }
        return (ssid, fields["P"] ?? "")
    }
}

/// Live camera preview for the scanner sheet.
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.wantsLayer = true
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer = preview
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView.layer as? AVCaptureVideoPreviewLayer)?.session = session
    }
}

// MARK: - Scan Sheet

/// Camera sheet that fills in the hotspot fields from the phone's QR and joins.
struct HotspotScanSheet: View {
    @ObservedObject var client: NetworkClient
    @StateObject private var scanner = HotspotQRScanner()

    var body: some View {
        VStack(spacing: 14) {
            Text("Scan the phone's QR")
                .font(.headline)

            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.6))
                if scanner.isRunning {
                    CameraPreview(session: scanner.session)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else if scanner.errorMessage == nil {
                    ProgressView()
                }
            }
            .frame(width: 300, height: 220)

            if let error = scanner.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("On the phone, tap Create Hotspot and hold its QR up to this camera.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    scanner.stop()
                    client.showHotspotScanner = false
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 340)
        .onAppear { scanner.start() }
        .onDisappear { scanner.stop() }
        .onChange(of: scanner.result?.ssid) { _ in
            guard let found = scanner.result else { return }
            client.hotspotSSID = found.ssid
            client.hotspotPassword = found.password
            client.showHotspotScanner = false
            client.joinHotspot()
        }
    }
}
