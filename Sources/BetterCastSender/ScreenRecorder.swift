import Foundation
import ScreenCaptureKit
import CoreMedia

class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
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
        do {
            // Retry logic for Virtual Display availability (Race condition fix)
            var display: SCDisplay?
            
            if let targetID = targetDisplayID {
                LogManager.shared.log("ScreenRecorder: Searching for target display \(targetID)...")
                for i in 0..<10 { // Retry 10 times (2 seconds max)
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
            config.queueDepth = captureFPS > 60 ? 8 : 4
            config.capturesAudio = captureAudio

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global(qos: .userInitiated))
            if captureAudio {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
                LogManager.shared.log("ScreenRecorder: Audio capture enabled")
            }
            
            try await stream.startCapture()
            self.stream = stream
            print("ScreenRecorder: Started capturing display \(display.displayID)")
            LogManager.shared.log("ScreenRecorder: Started capture for display \(display.displayID)")
            
        } catch {
            print("ScreenRecorder: Failed to start capture: \(error)")
            LogManager.shared.log("ScreenRecorder: Failed to start capture: \(error.localizedDescription)")
            
            if let scError = error as? SCStreamError, scError.code == .userDeclined {
                 LogManager.shared.log("ScreenRecorder: PERMISSION DENIED. Go to System Settings > Privacy > Screen Recording")
            }
        }
    }
    
    func stopCapture() {
        Task {
            try? await stream?.stopCapture()
            stream = nil
        }
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
        print("ScreenRecorder: Stream stopped with error: \(error)")
    }
}
