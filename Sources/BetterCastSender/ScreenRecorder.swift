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
        stopFramePump()
        Task {
            try? await stream?.stopCapture()
            stream = nil
        }
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
    private var lastSampleBuffer: CMSampleBuffer?   // newest frame; queueDepth is raised by 1 to compensate
    private var lastFrameHostTime: CFTimeInterval = 0

    private func startFramePump() {
        let timer = DispatchSource.makeTimerSource(queue: pumpQueue)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(33))
        timer.setEventHandler { [weak self] in
            guard let self = self, !self.stopRequested else { return }
            // Only pump when SCK has gone quiet; live capture always wins.
            guard CACurrentMediaTime() - self.lastFrameHostTime > 0.05,
                  let sb = self.lastSampleBuffer,
                  let pb = CMSampleBufferGetImageBuffer(sb) else { return }
            self.videoEncoder?.encodeRepeatFrame(pixelBuffer: pb)
        }
        timer.resume()
        pumpTimer = timer
    }

    private func stopFramePump() {
        pumpTimer?.cancel()
        pumpTimer = nil
        pumpQueue.async { [weak self] in self?.lastSampleBuffer = nil }
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
            pumpQueue.async { [weak self] in
                self?.lastSampleBuffer = sampleBuffer
                self?.lastFrameHostTime = CACurrentMediaTime()
            }

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
