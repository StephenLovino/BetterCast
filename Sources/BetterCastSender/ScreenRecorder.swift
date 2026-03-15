import Foundation
import ScreenCaptureKit
import CoreMedia

class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var videoEncoder: VideoEncoder?
    private var targetDisplayID: CGDirectDisplayID?
    
    private var width: Int
    private var height: Int
    
    init(videoEncoder: VideoEncoder, targetDisplayID: CGDirectDisplayID? = nil, width: Int = 1920, height: Int = 1080) {
        self.videoEncoder = videoEncoder
        self.targetDisplayID = targetDisplayID
        self.width = width
        self.height = height
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
            config.minimumFrameInterval = CMTime(value: 1, timescale: 120) // Allow up to 120 fps for ProMotion smoothnes
            config.queueDepth = 8 // Increase buffer for high FPS
            config.capturesAudio = false
            
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global(qos: .userInitiated))
            
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
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        
        frameCount += 1
        if frameCount % 60 == 0 {
            LogManager.shared.log("ScreenRecorder: Captured frame \(frameCount)")
        }
        
        // Send to encoder
        videoEncoder?.encode(sampleBuffer: sampleBuffer)
    }
    
    // SCStreamDelegate
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("ScreenRecorder: Stream stopped with error: \(error)")
    }
}
