import Foundation
import VideoToolbox
import CoreMedia

protocol VideoEncoderDelegate: AnyObject {
    func videoEncoder(_ encoder: VideoEncoder, didEncode data: Data, for connectionId: UUID, isKeyframe: Bool)
}

class VideoEncoder {
    weak var delegate: VideoEncoderDelegate?
    let connectionId: UUID
    private var compressionSession: VTCompressionSession?
    private var frameCount = 0
    private let bitrate: Int
    private let rateLimitWindow: Double
    private(set) var currentBitrate: Int
    // Adaptive bitrate state lives on the encoder (a class) — NOT in the pipelines
    // dictionary — so the video-encoder callback thread can update it without mutating
    // a shared Swift dictionary concurrently with the main thread (which corrupts the heap).
    var maxBitrate: Int = 0          // ceiling = user-selected quality
    var adaptFrames: Int = 0         // frames seen this window (infrastructure path)
    var adaptDrops: Int = 0          // frames dropped this window (backpressure)

    // Cache for headers so we can re-send them if needed
    private var cachedSPS: Data?
    private var cachedPPS: Data?

    private var pendingKeyFrameRequest = false
    private var pendingKeyFrameSilent = false
    private var lastKeyFrameTime: Date = Date.distantPast
    private let keyframeThrottleInterval: TimeInterval

    private var expectedFPS: Int

    init(connectionId: UUID, width: Int, height: Int, bitrate: Int = 20_000_000, expectedFPS: Int = 120, keyframeIntervalSeconds: Double = 10.0, rateLimitWindow: Double = 1.0) {
        self.connectionId = connectionId
        self.bitrate = bitrate
        self.currentBitrate = bitrate
        self.rateLimitWindow = rateLimitWindow
        self.expectedFPS = expectedFPS
        self.keyframeThrottleInterval = max(0.3, keyframeIntervalSeconds / 3.0) // Allow forced keyframes at 1/3 the interval
        
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: { (outputCallbackRefCon, _, status, flags, sampleBuffer) in
                guard let refCon = outputCallbackRefCon else { return }
                let encoder = Unmanaged<VideoEncoder>.fromOpaque(refCon).takeUnretainedValue()
                encoder.compressionCallback(status: status, flags: flags, sampleBuffer: sampleBuffer)
            },
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &compressionSession
        )
        
        if status != noErr {
            LogManager.shared.log("VideoEncoder: Failed to create session \(status)")
            return
        }
        
        guard let session = compressionSession else { return }
        
        // Configuration for Low-Latency Real-Time Encoding
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        
        let bitrateCF = bitrate as CFNumber
        // DataRateLimits uses BYTES per period. Shorter windows = tighter per-frame control.
        // P2P uses 0.1s (prevents AWDL buffer bloat), infrastructure uses 1.0s (more flexible).
        let bytesPerWindow = Int(Double(bitrate / 8) * 1.5 * rateLimitWindow)
        let limitCF = [bytesPerWindow, rateLimitWindow] as CFArray

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrateCF)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limitCF)
        
        // Keyframe Control — shorter interval = faster error recovery at cost of bandwidth
        let maxKeyFrameInterval = Int(keyframeIntervalSeconds * Double(expectedFPS))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: maxKeyFrameInterval as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: keyframeIntervalSeconds as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse) // Crucial for Real-Time
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: expectedFPS as CFNumber)
        // Emit each frame as soon as it's encoded — no rate-control lookahead buffering.
        // With no frame reordering this is safe and shaves a frame of latency off interactive
        // use (e.g. typing on an extended display mirrored to the receiver).
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 1 as CFNumber)

        VTCompressionSessionPrepareToEncodeFrames(session)
        LogManager.shared.log("VideoEncoder: Initialized (\(bitrate/1_000_000)Mbps, KF every \(keyframeIntervalSeconds)s)")
    }
    
    /// Request the next encodable frame be an IDR keyframe.
    /// - Parameter silent: pass true for high-frequency recovery requests (e.g. after a
    ///   dropped P-frame) so the log isn't spammed. A non-silent request always logs and
    ///   "wins" over a pending silent one.
    func forceKeyframe(silent: Bool = false) {
        if !silent {
            LogManager.shared.log("VideoEncoder: Keyframe Requested")
            pendingKeyFrameSilent = false
        } else if !pendingKeyFrameRequest {
            pendingKeyFrameSilent = true
        }
        pendingKeyFrameRequest = true
    }
    
    /// Adjust the target bitrate on a running session (adaptive bitrate for WiFi/infrastructure).
    /// Updates both AverageBitRate and DataRateLimits so frame sizes are constrained to match.
    func setTargetBitrate(_ newBitrate: Int) {
        guard let session = compressionSession, newBitrate != currentBitrate else { return }
        currentBitrate = newBitrate
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: newBitrate as CFNumber)
        let bytesPerWindow = Int(Double(newBitrate / 8) * 1.5 * rateLimitWindow)
        let limitCF = [bytesPerWindow, rateLimitWindow] as CFArray
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limitCF)
    }

    func encode(sampleBuffer: CMSampleBuffer) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        encodeFrame(imageBuffer: imageBuffer,
                    pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                    duration: CMSampleBufferGetDuration(sampleBuffer))
    }

    /// Encode a raw CVPixelBuffer directly. Used by the CGDisplayStream legacy capture
    /// path, which produces pixel buffers instead of CMSampleBuffers.
    func encodePixelBuffer(_ pixelBuffer: CVPixelBuffer, pts: CMTime, duration: CMTime = .invalid) {
        encodeFrame(imageBuffer: pixelBuffer, pts: pts, duration: duration)
    }

    /// Re-encode a held frame with a fresh host-clock timestamp. Used by the static-content
    /// frame pump: when the screen is idle, ScreenCaptureKit stops delivering frames, and
    /// hardware decoders (notably Android MediaCodec) hold 2-4 frames internally until more
    /// input pushes them through — so the last real change (e.g. a typed character) stays
    /// stuck inside the decoder. Repeating the previous frame keeps the pipeline flowing
    /// (same trick as scrcpy's repeat-previous-frame). Static repeats encode to tiny P-frames.
    // Monotonic PTS clock. encodeFrame() advances this from every real frame's PTS; repeats
    // derive their PTS as lastPTS + one frame interval so timestamps stay strictly increasing
    // in the SAME domain as real frames. Mixing a separate host clock made VideoToolbox
    // silently drop repeats on the discontinuity. Touched from two threads, so lock it.
    private var lastEncodedPTSSeconds: Double = 0
    private let ptsLock = NSLock()

    func encodeRepeatFrame(pixelBuffer: CVPixelBuffer) {
        let interval = 1.0 / Double(max(expectedFPS, 1))
        ptsLock.lock()
        let ptsSeconds = lastEncodedPTSSeconds + interval
        ptsLock.unlock()
        encodeFrame(imageBuffer: pixelBuffer,
                    pts: CMTime(seconds: ptsSeconds, preferredTimescale: 1_000_000_000),
                    duration: .invalid)
    }

    func encodeFrame(imageBuffer: CVImageBuffer, pts: CMTime, duration: CMTime) {
        guard let session = compressionSession else { return }
        frameCount += 1
        // Advance the monotonic PTS clock the repeat pump derives its timestamps from.
        if pts.seconds.isFinite {
            ptsLock.lock()
            if pts.seconds > lastEncodedPTSSeconds { lastEncodedPTSSeconds = pts.seconds }
            ptsLock.unlock()
        }
        var frameProperties: [String: Any] = [:]
        
        // Force keyframe if requested or first frame
        // Throttle forced keyframes — see keyframeThrottleInterval init
        let timeSinceLastKeyFrame = Date().timeIntervalSince(lastKeyFrameTime)
        
        if frameCount == 1 || (pendingKeyFrameRequest && timeSinceLastKeyFrame > keyframeThrottleInterval) {
             if !pendingKeyFrameSilent {
                 LogManager.shared.log("VideoEncoder: Forcing Keyframe (Frame \(frameCount))")
             }
             frameProperties[kVTEncodeFrameOptionKey_ForceKeyFrame as String] = kCFBooleanTrue
             pendingKeyFrameRequest = false
             pendingKeyFrameSilent = false
             lastKeyFrameTime = Date()
        } else if pendingKeyFrameRequest {
             // Request ignored due to throttling
             if !pendingKeyFrameSilent {
                 LogManager.shared.log("VideoEncoder: Keyframe Request Throttled (Last: \(timeSinceLastKeyFrame)s ago)")
             }
             pendingKeyFrameRequest = false // Clear it so we don't queue likely stale requests
             pendingKeyFrameSilent = false
        }
        
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: imageBuffer,
            presentationTimeStamp: pts,
            duration: duration,
            frameProperties: frameProperties as CFDictionary,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
        
        if status != noErr {
             LogManager.shared.log("VideoEncoder: Encode failed \(status)")
        }
    }
    
    private func compressionCallback(status: OSStatus, flags: VTEncodeInfoFlags, sampleBuffer: CMSampleBuffer?) {
        guard let sampleBuffer = sampleBuffer, status == noErr else {
            return
        }
        
        // Extract timestamp
        let presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        
        // Check if keyframe using Swift casting (Safe)
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        let isKeyframe = !notSync
        
        // 1. Extract and Cache Headers from this frame if present
        if let description = CMSampleBufferGetFormatDescription(sampleBuffer) {
            extractAndCacheParameterSets(from: description)
        }
        
        var coalescedData = Data()
        
        // 2. Handle Header Bundling for Keyframes
        if isKeyframe {
            
            if let description = CMSampleBufferGetFormatDescription(sampleBuffer) {
                var pCount: size_t = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &pCount, nalUnitHeaderLengthOut: nil)
                
                if pCount >= 2 {
                    // Extract from description
                     for i in 0..<pCount {
                        var pointer: UnsafePointer<UInt8>?
                        var size: Int = 0
                        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description, parameterSetIndex: i, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                        if let pointer = pointer {
                            var len = UInt32(size).bigEndian
                            coalescedData.append(Data(bytes: &len, count: 4))
                            coalescedData.append(Data(bytes: pointer, count: size))
                        }
                    }
                } else if let sps = cachedSPS, let pps = cachedPPS {
                    // Inject from cache
                    var lenSPS = UInt32(sps.count).bigEndian
                    coalescedData.append(Data(bytes: &lenSPS, count: 4))
                    coalescedData.append(sps)
                    
                    var lenPPS = UInt32(pps.count).bigEndian
                    coalescedData.append(Data(bytes: &lenPPS, count: 4))
                    coalescedData.append(pps)
                    LogManager.shared.log("VideoEncoder: Injected Cached SPS/PPS")
                }
            }
        }
        
        // 3. Append the Frame Data
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var lengthAtOffset: Int = 0
        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        
        if CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: &totalLength, dataPointerOut: &dataPointer) == noErr {
            
            var bufferOffset = 0
            let headerLength = 4 // AVCC 4 bytes length
            
            while bufferOffset < totalLength - headerLength {
                var atomLength: UInt32 = 0
                memcpy(&atomLength, dataPointer! + bufferOffset, 4)
                atomLength = UInt32(bigEndian: atomLength)
                
                bufferOffset += 4 // Skip length
                
                if bufferOffset + Int(atomLength) > totalLength { break }
                
                let nalData = Data(bytes: dataPointer! + bufferOffset, count: Int(atomLength))
                
                // Append [Len][NALU]
                var avccLen = UInt32(atomLength).bigEndian
                coalescedData.append(Data(bytes: &avccLen, count: 4))
                coalescedData.append(nalData)
                
                bufferOffset += Int(atomLength)
            }
        }
        
        // 4. Send One Megapacket (with PTS Header)
        if !coalescedData.isEmpty {
             var packetWithPTS = Data()
             // Convert PTS to UInt64 nanoseconds (8 bytes)
             var ptsNanos = UInt64(presentationTimeStamp.seconds * 1_000_000_000)
             packetWithPTS.append(Data(bytes: &ptsNanos, count: 8))
             packetWithPTS.append(coalescedData)
            
             delegate?.videoEncoder(self, didEncode: packetWithPTS, for: connectionId, isKeyframe: isKeyframe)
        }
    }
    
    private func extractAndCacheParameterSets(from description: CMVideoFormatDescription) {
        var parameterSetCount: size_t = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &parameterSetCount, nalUnitHeaderLengthOut: nil)
        
        if parameterSetCount < 2 { return }
        
        // Extract SPS (Index 0)
        var spsPointer: UnsafePointer<UInt8>?
        var spsSize: Int = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description, parameterSetIndex: 0, parameterSetPointerOut: &spsPointer, parameterSetSizeOut: &spsSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
        
        // Extract PPS (Index 1)
        var ppsPointer: UnsafePointer<UInt8>?
        var ppsSize: Int = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description, parameterSetIndex: 1, parameterSetPointerOut: &ppsPointer, parameterSetSizeOut: &ppsSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
        
        if let spsP = spsPointer, let ppsP = ppsPointer {
            let spsData = Data(bytes: spsP, count: spsSize)
            let ppsData = Data(bytes: ppsP, count: ppsSize)
            
            // Only update if changed
            if spsData != cachedSPS || ppsData != cachedPPS {
                cachedSPS = spsData
                cachedPPS = ppsData
                LogManager.shared.log("VideoEncoder: Cached new SPS/PPS headers")
            }
        }
    }
}
