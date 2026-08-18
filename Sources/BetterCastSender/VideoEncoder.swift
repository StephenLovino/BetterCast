import Foundation
import VideoToolbox
import CoreMedia

/// Which video codec a pipeline encodes with.
enum StreamCodec: String, CaseIterable, Identifiable {
    case h264
    case hevc
    var id: String { rawValue }
    var displayName: String { self == .hevc ? "H.265 (HEVC)" : "H.264" }
}

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
    // Per-second pipeline stats. Deliberately the same three numbers SideScreen logs
    // (fps, Mbps, avg frame age) and measured the same way — capture to emit — because
    // comparing our every-300-frames byte dump against their per-second aggregate was
    // guesswork. Reset by the 1 Hz stats pass that prints them.
    /// Exponentially smoothed measured throughput, bits per second. Fed by the 1 Hz
    /// stats pass. Exists so the shared-radio budget can be split by what each pipeline
    /// actually uses instead of an equal cut: an idle iPhone was reserving half the
    /// budget while spending none of it, and the Android was crushed against the rest.
    var smoothedBps: Double = 0

    var statsFrames: Int = 0
    var statsBytes: Int = 0
    var statsAgeSumMs: Double = 0
    var statsAgeCount: Int = 0
    /// Capture wall-clock per PTS, so age survives frames VideoToolbox never emits.
    private var captureTimesNs: [Int64: UInt64] = [:]
    private let captureTimesLock = NSLock()

    // Sends currently in flight on this pipeline's connection. Written from the encoder
    // callback thread (send start) and the network queue (send completion), hence the
    // lock. Only the infrastructure path ever increments it, so on P2P and USB it stays
    // zero and the pre-encode gate below can never fire there.
    private var inFlightSends: Int = 0
    private let inFlightLock = NSLock()
    func sendStarted() { inFlightLock.lock(); inFlightSends += 1; inFlightLock.unlock() }
    func sendFinished() { inFlightLock.lock(); inFlightSends = max(0, inFlightSends - 1); inFlightLock.unlock() }
    var sendsInFlight: Int { inFlightLock.lock(); defer { inFlightLock.unlock() }; return inFlightSends }

    var adaptFrames: Int = 0         // frames seen this window (infrastructure path)
    var adaptDrops: Int = 0          // frames dropped this window (backpressure)
    /// Drop ratio at the previous cut, or -1 when no cut is in progress. Lets the
    /// controller check whether cutting the bitrate is actually reducing drops before it
    /// cuts again — on an airtime-starved link it is not, and compounding is destructive.
    var lastAdaptDropRatio: Double = -1
    /// True while the controller has deliberately stopped cutting, so the explanatory
    /// log line is emitted once per episode rather than every second.
    var adaptHolding: Bool = false
    /// Consecutive backpressure drops. Distinguishes an isolated stall, which is worth
    /// chasing with a resync keyframe, from a blackout, where keyframes make it worse.
    var consecutiveDrops: Int = 0

    // Cache for headers so we can re-send them if needed
    private var cachedSPS: Data?
    private var cachedPPS: Data?
    /// HEVC only: the video parameter set, which H.264 has no equivalent of.
    private var cachedVPS: Data?

    /// Which codec this session encodes with.
    ///
    /// HEVC carries roughly 30-50% more picture per bit than H.264, which is the single
    /// largest difference between us and SideScreen — they default to it, we never had
    /// the option. The container is unchanged: HVCC is length-prefixed exactly like AVCC,
    /// so framing, the PTS header and the receiver's NALU walk all work as they are.
    let codec: StreamCodec

    private var pendingKeyFrameRequest = false
    private var pendingKeyFrameSilent = false
    private var lastKeyFrameTime: Date = Date.distantPast
    private let keyframeThrottleInterval: TimeInterval

    private var expectedFPS: Int

    /// How far a single rate-limit window may exceed the average bitrate.
    ///
    /// DataRateLimits is what stops AWDL buffer bloat, but it is also a hard ceiling on
    /// burst: when the picture moves, the encoder wants far more bits than the average
    /// and VideoToolbox's only way to obey the cap is to drop quality. That is the
    /// "goes soft the moment anything moves" complaint. 1.5x is safe for P2P; a looser
    /// ceiling lets motion keep its detail on infrastructure Wi-Fi, at the cost of
    /// burstier traffic — which adaptive bitrate is there to absorb.
    var burstMultiplier: Double = 1.5

    // codec is an init parameter, not a property set afterwards: the compression session
    // is built right here, so assigning it later left the session encoding H.264 while
    // every parameter-set read used the HEVC API. Those return nothing for an H.264
    // description, so no VPS/SPS/PPS was ever cached or bundled and the receiver sat on a
    // black screen with no way to configure its decoder.
    init(connectionId: UUID, width: Int, height: Int, bitrate: Int = 20_000_000, expectedFPS: Int = 120, keyframeIntervalSeconds: Double = 10.0, rateLimitWindow: Double = 1.0, codec: StreamCodec = .h264) {
        self.codec = codec
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
            codecType: codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
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
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel
                                                   : kVTProfileLevel_H264_High_AutoLevel)
        
        let bitrateCF = bitrate as CFNumber
        // DataRateLimits uses BYTES per period. Shorter windows = tighter per-frame control.
        // P2P uses 0.1s (prevents AWDL buffer bloat), infrastructure uses 1.0s (more flexible).
        let bytesPerWindow = Int(Double(bitrate / 8) * burstMultiplier * rateLimitWindow)
        let limitCF = [bytesPerWindow, rateLimitWindow] as CFArray

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrateCF)
        // Only where it earns its keep. On AWDL a tight window is what stops peer-to-peer
        // buffer bloat, and on the WiFi-ADB tunnel it stops kernel buffer growth. On plain
        // infrastructure it is a burst ceiling and nothing else, and a burst is exactly
        // what a moving picture needs — SideScreen deleted the same property outright,
        // noting it "was causing bursty traffic and buffer stalls".
        if rateLimitWindow < 1.0 {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limitCF)
        }
        
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
        LogManager.shared.log("VideoEncoder: Initialized (\(codec == .hevc ? "H.265" : "H.264"), \(bitrate/1_000_000)Mbps, KF every \(keyframeIntervalSeconds)s)")
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
        guard rateLimitWindow < 1.0 else { return }   // infrastructure runs uncapped
        let bytesPerWindow = Int(Double(newBitrate / 8) * burstMultiplier * rateLimitWindow)
        let limitCF = [bytesPerWindow, rateLimitWindow] as CFArray
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limitCF)
    }

    /// Change the burst ceiling on a running session, without a reconnect.
    func setBurstMultiplier(_ value: Double) {
        guard let session = compressionSession, value != burstMultiplier else { return }
        burstMultiplier = value
        guard rateLimitWindow < 1.0 else { return }   // infrastructure runs uncapped
        let bytesPerWindow = Int(Double(currentBitrate / 8) * burstMultiplier * rateLimitWindow)
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

        // Flow control belongs BEFORE the encoder, not after it (SideScreen's design).
        // A frame skipped here was never encoded, so the next encoded frame still
        // references the last one that was — the reference chain is intact and the
        // receiver sees a briefly lower frame rate, which is invisible. Dropping an
        // already-encoded frame instead breaks the chain and pixelates the picture
        // until the next keyframe, which was the "flaky whenever the output moves".
        // Keyframe requests always pass: they exist to resync a struggling link.
        if frameCount > 0 && !pendingKeyFrameRequest && sendsInFlight >= 2 {
            adaptFrames += 1
            adaptDrops += 1
            return
        }
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
        
        captureTimesLock.lock()
        // Bound it: a stalled encoder must not grow this without limit.
        if captureTimesNs.count > 256 { captureTimesNs.removeAll() }
        captureTimesNs[pts.value] = DispatchTime.now().uptimeNanoseconds
        captureTimesLock.unlock()

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

        // Age = capture to emit, matching how SideScreen measures it.
        captureTimesLock.lock()
        if let capturedAt = captureTimesNs.removeValue(forKey: presentationTimeStamp.value) {
            let ageMs = Double(DispatchTime.now().uptimeNanoseconds - capturedAt) / 1_000_000.0
            statsAgeSumMs += ageMs
            statsAgeCount += 1
        }
        captureTimesLock.unlock()
        
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
                parameterSet(description, 0, nil, nil, &pCount)

                // HEVC ships three parameter sets (VPS, SPS, PPS); H.264 ships two.
                let requiredSets = codec == .hevc ? 3 : 2
                if pCount >= requiredSets {
                    // Extract from description
                     for i in 0..<pCount {
                        var pointer: UnsafePointer<UInt8>?
                        var size: Int = 0
                        parameterSet(description, i, &pointer, &size, nil)
                        if let pointer = pointer {
                            var len = UInt32(size).bigEndian
                            coalescedData.append(Data(bytes: &len, count: 4))
                            coalescedData.append(Data(bytes: pointer, count: size))
                        }
                    }
                } else if let sps = cachedSPS, let pps = cachedPPS {
                    // Inject from cache. Order matters: a decoder needs VPS before SPS.
                    if codec == .hevc, let vps = cachedVPS {
                        var lenVPS = UInt32(vps.count).bigEndian
                        coalescedData.append(Data(bytes: &lenVPS, count: 4))
                        coalescedData.append(vps)
                    }
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
    
    /// Count/fetch parameter sets for whichever codec this session uses.
    /// HEVC exposes three (VPS, SPS, PPS) where H.264 exposes two.
    private func parameterSet(_ description: CMVideoFormatDescription, _ index: Int,
                              _ pointer: UnsafeMutablePointer<UnsafePointer<UInt8>?>?,
                              _ size: UnsafeMutablePointer<Int>?,
                              _ count: UnsafeMutablePointer<Int>?) {
        if codec == .hevc {
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(description, parameterSetIndex: index,
                parameterSetPointerOut: pointer, parameterSetSizeOut: size,
                parameterSetCountOut: count, nalUnitHeaderLengthOut: nil)
        } else {
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description, parameterSetIndex: index,
                parameterSetPointerOut: pointer, parameterSetSizeOut: size,
                parameterSetCountOut: count, nalUnitHeaderLengthOut: nil)
        }
    }

    private func extractAndCacheParameterSets(from description: CMVideoFormatDescription) {
        var parameterSetCount: size_t = 0
        parameterSet(description, 0, nil, nil, &parameterSetCount)

        // HEVC: [0]=VPS, [1]=SPS, [2]=PPS. H.264: [0]=SPS, [1]=PPS.
        let spsIndex = codec == .hevc ? 1 : 0
        let ppsIndex = codec == .hevc ? 2 : 1
        if parameterSetCount < (codec == .hevc ? 3 : 2) { return }

        if codec == .hevc {
            var vpsPointer: UnsafePointer<UInt8>?
            var vpsSize: Int = 0
            parameterSet(description, 0, &vpsPointer, &vpsSize, nil)
            if let p = vpsPointer { cachedVPS = Data(bytes: p, count: vpsSize) }
        }

        var spsPointer: UnsafePointer<UInt8>?
        var spsSize: Int = 0
        parameterSet(description, spsIndex, &spsPointer, &spsSize, nil)

        var ppsPointer: UnsafePointer<UInt8>?
        var ppsSize: Int = 0
        parameterSet(description, ppsIndex, &ppsPointer, &ppsSize, nil)
        
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
