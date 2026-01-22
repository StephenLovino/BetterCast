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
            let content = try await SCShareableContent.current
            
            // Find the target display (virtual display if provided, otherwise main)
            let display: SCDisplay?
            if let targetID = targetDisplayID {
                display = content.displays.first { $0.displayID == targetID }
                if display == nil {
                    LogManager.shared.log("ScreenRecorder: Virtual display \(targetID) not found, falling back to main")
                }
            } else {
                display = content.displays.first
            }
            
            guard let display = display else {
                LogManager.shared.log("ScreenRecorder: No display found")
                return
            }
            
            let filter = SCContentFilter(display: display, excludingWindows: [])
            
            let config = SCStreamConfiguration()
            config.width = width
            config.height = height
            config.minimumFrameInterval = CMTime(value: 1, timescale: 60) // 60 fps
            config.queueDepth = 5
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
