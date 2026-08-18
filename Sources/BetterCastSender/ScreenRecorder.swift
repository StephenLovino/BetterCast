import Foundation
import ScreenCaptureKit
import CoreMedia
import QuartzCore

class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    // Set when stopCapture() is called. startCapture() runs async and spends up to ~2s
    // retrying to find the virtual display before it assigns `stream`. If a stop lands
    // during that window it would no-op on a nil stream and the about-to-start stream
    // would leak — capturing forever with no way to stop it. This flag lets an in-flight
    // start abort and tear itself down.
    private var stopRequested = false
    private var videoEncoder: VideoEncoder?
    private var targetDisplayID: CGDirectDisplayID?
    var audioEncoder: AudioEncoder?
    var captureAudio: Bool = false

    /// When true, uses CGDisplayStream instead of ScreenCaptureKit to capture.
    /// CGDisplayStream reads the GPU's composited framebuffer directly, which bypasses
    /// SCK's DRM/HDCP blocking. Only works for physical displays (not virtual).
    /// Set before calling startCapture().
    var useLegacyCapture: Bool = false
    private var legacyCapture: LegacyDisplayCapture?

    private var width: Int
    private var height: Int
    private var captureFPS: Int32

    init(videoEncoder: VideoEncoder, targetDisplayID: CGDirectDisplayID? = nil, width: Int = 1920, height: Int = 1080, captureFPS: Int32 = 120) {
        self.videoEncoder = videoEncoder
        self.targetDisplayID = targetDisplayID
        self.width = width
        self.height = height
        self.captureFPS = captureFPS
        super.init()
    }
    
    func startCapture() async {
        stopRequested = false

        // ── Legacy capture path (CGDisplayStream) ──
        if useLegacyCapture {
            await startLegacyCapture()
            return
        }

        do {
            // Retry logic for Virtual Display availability (Race condition fix)
            var display: SCDisplay?

            if let targetID = targetDisplayID {
                LogManager.shared.log("ScreenRecorder: Searching for target display \(targetID)...")
                for i in 0..<10 { // Retry 10 times (2 seconds max)
                    if stopRequested { return } // Bail if torn down mid-search
                    let content = try await SCShareableContent.current
                    if let match = content.displays.first(where: { $0.displayID == targetID }) {
                        display = match
                        LogManager.shared.log("ScreenRecorder: Found target display on attempt \(i+1)")
                        break
                    }
                    try await Task.sleep(nanoseconds: 200_000_000) // 200ms
                }
                
                if display == nil {
                    LogManager.shared.log("ScreenRecorder: Target display \(targetID) NOT found after retries. Falling back to Main.")
                }
            }
            
            // Fallback to Main Display explicitly if target not found or not specified
            if display == nil {
                 let content = try await SCShareableContent.current
                 // Use CGMainDisplayID to ensure we get the primary screen, not just 'first'
                 let mainID = CGMainDisplayID()
                 display = content.displays.first { $0.displayID == mainID }
                 
                 // Ultimate fallback
                 if display == nil { display = content.displays.first }
            }
            
            guard let display = display else {
                LogManager.shared.log("ScreenRecorder: No display found")
                return
            }
            
            let filter = SCContentFilter(display: display, excludingWindows: [])
            
            let config = SCStreamConfiguration()
            config.width = width
            config.height = height
            config.minimumFrameInterval = CMTime(value: 1, timescale: captureFPS)
            // Low queue depth = less capture-side buffering = lower input-to-display latency.
            // 4 instead of 3 because the frame pump retains the newest buffer from this pool;
            // SCK still has 3 free buffers in flight, so effective latency is unchanged.
            config.queueDepth = captureFPS > 60 ? 8 : 4
            config.capturesAudio = captureAudio

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global(qos: .userInitiated))
            if captureAudio {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
                LogManager.shared.log("ScreenRecorder: Audio capture enabled")
            }
            
            // Publish the stream before starting so a concurrent stopCapture() can see it.
            self.stream = stream
            if stopRequested {
                self.stream = nil
                LogManager.shared.log("ScreenRecorder: Start aborted — stop requested during setup")
                return
            }

            try await stream.startCapture()

            // A stop may have landed between the check above and startCapture completing.
            if stopRequested {
                try? await stream.stopCapture()
                self.stream = nil
                LogManager.shared.log("ScreenRecorder: Started then immediately stopped — stop requested mid-start")
                return
            }
            LogManager.shared.log("ScreenRecorder: Started capture for display \(display.displayID)")
            startFramePump()

        } catch {
            LogManager.shared.log("ScreenRecorder: Failed to start capture: \(error.localizedDescription)")
            self.stream = nil // Release a partially-created stream so it doesn't linger

            if let scError = error as? SCStreamError, scError.code == .userDeclined {
                 LogManager.shared.log("ScreenRecorder: PERMISSION DENIED. Go to System Settings > Privacy > Screen Recording")
            }
        }
    }
    
    func stopCapture() {
        stopRequested = true // Aborts an in-flight startCapture() that hasn't published its stream yet
        legacyCapture?.stop()
        legacyCapture = nil
        stopFramePump()
        Task {
            try? await stream?.stopCapture()
            stream = nil
        }
    }

    // MARK: - Legacy capture (CGDisplayStream — DRM bypass)

    private func startLegacyCapture() async {
        // CGDisplayStream only works with physical displays that have a hardware framebuffer.
        // Virtual displays are software-only; detect and fall back to the main display.
        let captureDisplayID: CGDirectDisplayID
        if let tid = targetDisplayID {
            // Check whether this display is online (physical) or likely virtual.
            // CGGetOnlineDisplayList returns currently active physical displays.
            var onlineCount: UInt32 = 0
            var onlineIDs = [CGDirectDisplayID](repeating: 0, count: 16)
            CGGetOnlineDisplayList(16, &onlineIDs, &onlineCount)
            let isOnline = onlineIDs.prefix(Int(onlineCount)).contains(tid)
            if isOnline {
                captureDisplayID = tid
            } else {
                LogManager.shared.log("ScreenRecorder: Target display \(tid) is not online (virtual?) — falling back to main display for legacy capture")
                captureDisplayID = CGMainDisplayID()
            }
        } else {
            captureDisplayID = CGMainDisplayID()
        }
        LogManager.shared.log("ScreenRecorder: Legacy capture targeting display \(captureDisplayID)")

        let capture = LegacyDisplayCapture(
            displayID: captureDisplayID,
            width: width,
            height: height,
            fps: captureFPS
        )
        capture.onFrame = { [weak self] pixelBuffer, pts in
            guard let self = self, !self.stopRequested else { return }
            // Feed directly into the encoder.
            self.videoEncoder?.encodePixelBuffer(pixelBuffer, pts: pts, duration: .invalid)
            // Update the pump buffer so static-content repeats are fresh.
            self.updatePumpFrame(from: pixelBuffer)
            let nowReal = CACurrentMediaTime()
            self.encodeTimeLock.lock(); self.lastEncodeHostTime = nowReal; self.encodeTimeLock.unlock()
            self.lastFrameHostTime = nowReal
        }
        self.legacyCapture = capture
        capture.start()
        startFramePump()
        LogManager.shared.log("ScreenRecorder: Legacy capture started for display \(captureDisplayID)")
    }

    // MARK: - Static-content frame pump
    // ScreenCaptureKit only delivers frames when content changes. Hardware decoders on the
    // receiver (Android MediaCodec especially) hold 2-4 frames internally and only release
    // them as more input arrives — so on a static screen the last real change (a typed
    // character, a cursor stop) stays stuck inside the decoder for hundreds of ms. Repeat
    // the most recent frame at ~30fps while capture is idle to keep the pipeline flushed
    // (scrcpy's repeat-previous-frame, done sender-side). Repeats encode to tiny P-frames.
    private let pumpQueue = DispatchQueue(label: "com.bettercast.framepump")
    private var pumpTimer: DispatchSourceTimer?
    private var lastFrameHostTime: CFTimeInterval = 0
    // Owned copy of the most recent frame. We can't retain the SCK sample buffer for this:
    // when capture goes idle SCK reclaims its pool, so the held buffer's backing vanishes
    // exactly when the pump needs it. Copying into a buffer we own keeps a valid frame to
    // repeat indefinitely. Written on the SCK thread, read on the pump queue, hence the lock.
    private var pumpFrameBuffer: CVPixelBuffer?
    private let pumpBufferLock = NSLock()
    // Floor pacing: time of the most recent encode of ANY kind (real SCK frame or pump repeat).
    // Written from the SCK callback thread and the pump queue, so guard with a lock.
    private var lastEncodeHostTime: CFTimeInterval = 0
    private let encodeTimeLock = NSLock()
    // Floor interval, derived from the pipeline's target frame rate rather than fixed.
    //
    // This was hardcoded to 0.015 — a 66fps floor — no matter what the user chose. At a
    // 60fps setting, real capture runs around 50fps during motion (20ms apart), which is
    // slower than a 15ms floor, so the pump fired *between* real frames instead of only
    // when idle: measured 71-81fps of encodes against a 60fps setting. Three costs, all
    // paid exactly when the picture is moving. VideoToolbox is told ExpectedFrameRate=60
    // and then handed 78, so its bit allocation is wrong; the stream overshoots its
    // ceiling (20.4-21.5 Mbps against a 20 Mbps target); and the budget is divided across
    // ~30% more frames, so every real frame gets fewer bits. That reads as pixelation and
    // blur on scroll.
    //
    // The value now matches this pump's own documented intent, three lines above: repeat
    // "at ~30fps while capture is idle". 30fps is plenty to keep a decoder flushed, and it
    // sits far enough below any real capture rate that motion never triggers it. Never
    // faster than the target rate either, so a 30fps pipeline does not get 30fps of
    // repeats on top of 30fps of real frames.
    private var pumpFloorInterval: CFTimeInterval {
        max(1.0 / Double(max(captureFPS, 1)), 1.0 / 30.0)
    }

    /// Copy the latest captured frame into a buffer we own, so the pump always has a valid
    /// frame to repeat even after ScreenCaptureKit goes idle and recycles its pool. Reuses
    /// the destination buffer across frames; reallocates only on a size/format change.
    private func updatePumpFrame(from src: CVPixelBuffer) {
        let w = CVPixelBufferGetWidth(src)
        let h = CVPixelBufferGetHeight(src)
        let fmt = CVPixelBufferGetPixelFormatType(src)
        pumpBufferLock.lock()
        defer { pumpBufferLock.unlock() }
        if pumpFrameBuffer == nil ||
            CVPixelBufferGetWidth(pumpFrameBuffer!) != w ||
            CVPixelBufferGetHeight(pumpFrameBuffer!) != h ||
            CVPixelBufferGetPixelFormatType(pumpFrameBuffer!) != fmt {
            var nb: CVPixelBuffer?
            let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
            CVPixelBufferCreate(kCFAllocatorDefault, w, h, fmt, attrs as CFDictionary, &nb)
            pumpFrameBuffer = nb
        }
        guard let dst = pumpFrameBuffer else { return }
        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        if CVPixelBufferIsPlanar(src) {
            for p in 0..<CVPixelBufferGetPlaneCount(src) {
                guard let s = CVPixelBufferGetBaseAddressOfPlane(src, p),
                      let d = CVPixelBufferGetBaseAddressOfPlane(dst, p) else { continue }
                let sBPR = CVPixelBufferGetBytesPerRowOfPlane(src, p)
                let dBPR = CVPixelBufferGetBytesPerRowOfPlane(dst, p)
                let bytes = min(sBPR, dBPR)
                for row in 0..<CVPixelBufferGetHeightOfPlane(src, p) {
                    memcpy(d + row * dBPR, s + row * sBPR, bytes)
                }
            }
        } else if let s = CVPixelBufferGetBaseAddress(src), let d = CVPixelBufferGetBaseAddress(dst) {
            let sBPR = CVPixelBufferGetBytesPerRow(src)
            let dBPR = CVPixelBufferGetBytesPerRow(dst)
            let bytes = min(sBPR, dBPR)
            for row in 0..<h { memcpy(d + row * dBPR, s + row * sBPR, bytes) }
        }
        CVPixelBufferUnlockBaseAddress(dst, [])
        CVPixelBufferUnlockBaseAddress(src, .readOnly)
    }

    private func startFramePump() {
        let timer = DispatchSource.makeTimerSource(queue: pumpQueue)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(8))
        timer.setEventHandler { [weak self] in
            guard let self = self, !self.stopRequested else { return }
            // Maintain a ~60fps floor of encodes. Gate on time since the last encode of ANY
            // kind — not since the last SCK frame — so we fill the gap whether the screen went
            // static OR the encoder dropped a real frame. This keeps the Android decoder's
            // ~15-frame pipeline flushed so the newest content (a keystroke) isn't stuck for
            // seconds when capture goes quiet. scrcpy's repeat-previous-frame, output-paced.
            let now = CACurrentMediaTime()
            self.encodeTimeLock.lock()
            let gap = now - self.lastEncodeHostTime
            self.encodeTimeLock.unlock()
            guard gap >= self.pumpFloorInterval else { return }
            self.pumpBufferLock.lock()
            let pb = self.pumpFrameBuffer
            self.pumpBufferLock.unlock()
            guard let pb = pb else { return }
            self.encodeTimeLock.lock(); self.lastEncodeHostTime = now; self.encodeTimeLock.unlock()
            self.videoEncoder?.encodeRepeatFrame(pixelBuffer: pb)
        }
        timer.resume()
        pumpTimer = timer
    }

    private func stopFramePump() {
        pumpTimer?.cancel()
        pumpTimer = nil
        pumpBufferLock.lock(); pumpFrameBuffer = nil; pumpBufferLock.unlock()
    }

    // SCStreamOutput
    private var frameCount = 0
    private var audioFrameCount = 0
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            frameCount += 1
            if frameCount % 300 == 0 {
                LogManager.shared.log("ScreenRecorder: Captured frame \(frameCount)")
            }
            videoEncoder?.encode(sampleBuffer: sampleBuffer)
            let nowReal = CACurrentMediaTime()
            // Copy the frame into our own buffer now, while it's still valid on this thread.
            if let pb = CMSampleBufferGetImageBuffer(sampleBuffer) {
                updatePumpFrame(from: pb)
            }
            encodeTimeLock.lock(); lastEncodeHostTime = nowReal; encodeTimeLock.unlock()
            lastFrameHostTime = nowReal

        case .audio:
            audioFrameCount += 1
            if audioFrameCount % 200 == 1 {
                LogManager.shared.log("ScreenRecorder: Audio frame \(audioFrameCount)")
            }
            audioEncoder?.encode(sampleBuffer: sampleBuffer)

        @unknown default:
            break
        }
    }
    
    // SCStreamDelegate
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        LogManager.shared.log("ScreenRecorder: Stream stopped with error: \(error.localizedDescription)")
    }
}
