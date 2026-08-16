import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
import VideoToolbox
import QuartzCore

/// Captures display frames via CGDisplayStream — the "direct display output" path
/// that reads the GPU's composited framebuffer rather than going through
/// ScreenCaptureKit's DRM-aware compositor API.
///
/// CGDisplayStream was introduced in macOS 10.8. While deprecated, it remains
/// functional on macOS 27 (Sonoma) and is the only way to capture DRM-protected
/// content (Netflix, Apple TV, etc.) because the GPU has already decoded the
/// protected frames into the final composited framebuffer. ScreenCaptureKit
/// explicitly blocks HDCP/DRM content — this path does not.
///
/// Trade-offs vs SCK:
///   - Can capture DRM content ✓
///   - Slightly higher GPU readback cost (software read of framebuffer)
///   - Outputs BGRA (needs VTPixelTransfer → NV12 for efficient H.264 encoding)
///   - Only works for PHYSICAL displays (virtual displays have no HW framebuffer)
class LegacyDisplayCapture {
    private var displayStream: CGDisplayStream?
    private var displayID: CGDirectDisplayID
    private var outputWidth: Int
    private var outputHeight: Int
    private var targetFPS: Int32

    /// Callback when a new frame is available as a CVPixelBuffer.
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?

    /// True after stop() is called; the stream handler checks this and drops frames.
    private var stopped = false

    /// BGRA → NV12 converter. Reused across frames; recreated on size change.
    private var transferSession: VTPixelTransferSession?
    private var lastSrcWidth: Int = 0
    private var lastSrcHeight: Int = 0

    /// Frame rate limiter — CGDisplayStream fires at display refresh rate (60-120 Hz).
    /// We gate encodes to ~targetFPS so the encoder isn't flooded.
    private var lastFrameHostTime: Double = 0
    private let minFrameInterval: Double

    /// Owned NV12 buffer reused across frames to avoid allocation churn.
    private var nv12Buffer: CVPixelBuffer?

    private let streamQueue = DispatchQueue(label: "com.bettercast.legacy-capture", qos: .userInteractive)

    init(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int32 = 60) {
        self.displayID = displayID
        self.outputWidth = width
        self.outputHeight = height
        self.targetFPS = fps
        self.minFrameInterval = 1.0 / Double(fps)
    }

    func start() {
        stopped = false
        lastFrameHostTime = 0

        // CGDisplayStream delivers frames at the display's native resolution.
        // We request the output size we want (scaling is done by the GPU).
        // Pixel format: BGRA is what CGDisplayStream natively outputs.
        let pixelFormat = Int32(kCVPixelFormatType_32BGRA)

        // Properties dictionary: we don't need any special properties.
        let properties: CFDictionary? = nil

        let stream = CGDisplayStream(
            dispatchQueueDisplay: displayID,
            outputWidth: outputWidth,
            outputHeight: outputHeight,
            pixelFormat: pixelFormat,
            properties: properties,
            queue: streamQueue,
            handler: { [weak self] status, displayTime, frameSurface, updateRef in
                self?.handleFrame(status: status, displayTime: displayTime,
                                 frameSurface: frameSurface)
            }
        )

        guard let stream = stream else {
            LogManager.shared.log("LegacyDisplayCapture: Failed to create CGDisplayStream for display \(displayID)")
            return
        }

        self.displayStream = stream
        stream.start()
        LogManager.shared.log("LegacyDisplayCapture: Started CGDisplayStream for display \(displayID) @ \(outputWidth)x\(outputHeight) \(targetFPS)fps")
    }

    func stop() {
        stopped = true
        if let stream = displayStream {
            stream.stop()
            displayStream = nil
        }
        transferSession = nil
        nv12Buffer = nil
        LogManager.shared.log("LegacyDisplayCapture: Stopped")
    }

    // MARK: - Frame handling

    private func handleFrame(status: CGDisplayStreamFrameStatus, displayTime: UInt64,
                             frameSurface: IOSurface?) {
        guard !stopped else { return }

        // Only process complete frames.
        guard status == .frameComplete, let surface = frameSurface else { return }

        // Frame rate limiter — CGDisplayStream fires every ~16ms at 60Hz
        // (or ~8ms at 120Hz). Gate to targetFPS.
        let now = CACurrentMediaTime()
        let gap = now - lastFrameHostTime
        if gap < minFrameInterval * 0.95 {
            return // Skip this frame — too soon since last encode
        }
        lastFrameHostTime = now

        // Convert IOSurface → CVPixelBuffer (BGRA).
        // CVPixelBufferCreateWithIOSurface returns an Unmanaged<CVPixelBuffer>? because
        // the CGDisplayStream owns the IOSurface; we take a retained reference.
        var unmanagedPB: Unmanaged<CVPixelBuffer>?
        let status2 = CVPixelBufferCreateWithIOSurface(
            kCFAllocatorDefault,
            surface,
            nil, // no additional attributes
            &unmanagedPB
        )
        guard status2 == kCVReturnSuccess, let src = unmanagedPB?.takeRetainedValue() else {
            // Log only first failure to avoid spam.
            if status2 != kCVReturnSuccess {
                LogManager.shared.log("LegacyDisplayCapture: CVPixelBufferCreateWithIOSurface failed (\(status2))")
            }
            return
        }

        // Convert BGRA → NV12 for efficient H.264 encoding.
        // VideoToolbox can accept BGRA but NV12 is the native format and
        // avoids an internal conversion in the encoder hot path.
        let nv12 = convertToNV12(from: src)
        guard let nv12 = nv12 else { return }

        // Create CMTime from host clock (displayTime is in mach_absolute_time units;
        // we use our monotonic host clock for simplicity since PTS tracking is done
        // in VideoEncoder).
        let pts = CMTime(seconds: now, preferredTimescale: 1_000_000_000)
        onFrame?(nv12, pts)
    }

    // MARK: - BGRA → NV12 conversion

    /// Converts a BGRA CVPixelBuffer to NV12 (BiPlanar 4:2:0) using
    /// VTPixelTransferSession. The destination buffer is reused across frames
    /// and only reallocated on size change.
    private func convertToNV12(from src: CVPixelBuffer) -> CVPixelBuffer? {
        let srcW = CVPixelBufferGetWidth(src)
        let srcH = CVPixelBufferGetHeight(src)

        // Recreate the transfer session if the source size changes.
        if transferSession == nil || srcW != lastSrcWidth || srcH != lastSrcHeight {
            var session: VTPixelTransferSession?
            let status = VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault,
                                                       pixelTransferSessionOut: &session)
            guard status == noErr, let s = session else {
                LogManager.shared.log("LegacyDisplayCapture: VTPixelTransferSessionCreate failed (\(status))")
                return nil
            }
            transferSession = s
            lastSrcWidth = srcW
            lastSrcHeight = srcH
            nv12Buffer = nil // Force reallocation below
        }

        guard let session = transferSession else { return nil }

        // Reuse or create the NV12 destination buffer.
        if nv12Buffer == nil ||
            CVPixelBufferGetWidth(nv12Buffer!) != srcW ||
            CVPixelBufferGetHeight(nv12Buffer!) != srcH {
            var dst: CVPixelBuffer?
            let attrs: [CFString: Any] = [
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey: srcW,
                kCVPixelBufferHeightKey: srcH,
            ]
            CVPixelBufferCreate(kCFAllocatorDefault, srcW, srcH,
                                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                attrs as CFDictionary, &dst)
            nv12Buffer = dst
        }

        guard let dst = nv12Buffer else { return nil }

        let status = VTPixelTransferSessionTransferImage(session, from: src, to: dst)
        guard status == noErr else {
            LogManager.shared.log("LegacyDisplayCapture: VTPixelTransferSessionTransferImage failed (\(status))")
            return nil
        }

        return dst
    }
}
