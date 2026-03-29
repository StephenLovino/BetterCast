import Foundation
import VideoToolbox
import CoreMedia

protocol VideoDecoderDelegate: AnyObject {
    func didDecode(sampleBuffer: CMSampleBuffer)
}

class VideoDecoder: ObservableObject {
    @Published var decoderState: String = "Waiting for Data..."
    @Published var decodedFrameCount: Int = 0
    
    weak var delegate: VideoDecoderDelegate?
    private var decompressionSession: VTDecompressionSession?
    
    deinit {
        if let session = decompressionSession {
            // CRITICAL: Invalidate session to ensure no callbacks fire after deallocation.
            // This prevents EXC_BAD_ACCESS when the C-API tries to call back into a destroyed Swift object.
            VTDecompressionSessionInvalidate(session)
        }
        LogManager.shared.log("VideoDecoder: Deallocated")
    }
    
    private var formatDescription: CMVideoFormatDescription?
    
    // NALU buffer management
    private var sps: Data?
    private var pps: Data?
    
    private var timeOffset: Double = 0
    
    func decode(data: Data) {
        // Expected format: [PTS: 8 bytes][NALUs...]
        guard data.count > 8 else { return }
        
        let ptsData = data.prefix(8)
        
        // Use standard uInt64 instantiation to handle native endianness (matching Sender)
        var ptsNanos: UInt64 = 0
        let _ = Swift.withUnsafeMutableBytes(of: &ptsNanos) { ptr in
            ptsData.copyBytes(to: ptr)
        }
        
        // let ptsNanosSafe = rawValue // Renaming to ptsNanos for consistency with existing code usage below

        // Create a fresh Data object to reset indices to 0.
        // data.dropFirst(8) creates a Slice with startIndex=8, causing subdata(0..<4) to crash.
        let videoData = Data(data.dropFirst(8))
        
        // Scan for SPS/PPS in the received data (which might contain multiple NALUs)
        var offset = 0
        let totalLen = videoData.count
        
        while offset + 4 <= totalLen {
            let lenBuf = videoData.subdata(in: offset..<offset+4)
            let naluLen = Int(UInt32(bigEndian: lenBuf.withUnsafeBytes { $0.load(as: UInt32.self) }))
            
            if offset + 4 + naluLen > totalLen { break }
            
            let naluHeader = videoData[offset + 4]
            let naluType = naluHeader & 0x1F
            
            if naluType == 7 { // SPS
                sps = videoData.subdata(in: offset+4 ..< offset+4+naluLen)
            } else if naluType == 8 { // PPS
                pps = videoData.subdata(in: offset+4 ..< offset+4+naluLen)
            }
            
            offset += 4 + naluLen
        }
        
        // Try to initialize session if we found new headers
        createDecompressionSessionIfReady()
        
        if decompressionSession != nil {
            decodeFrame(data: videoData, ptsNanos: ptsNanos)
        }
    }
    
    private func createDecompressionSessionIfReady() {
        guard let sps = sps, let pps = pps else { return }

        // Create Format Description from SPS/PPS
        let parameterSets = [sps, pps]
        let parameterSetPointers = parameterSets.map { ($0 as NSData).bytes.bindMemory(to: UInt8.self, capacity: $0.count) }
        let parameterSetSizes = parameterSets.map { $0.count }

        var _formatDescription: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: kCFAllocatorDefault,
            parameterSetCount: 2,
            parameterSetPointers: parameterSetPointers,
            parameterSetSizes: parameterSetSizes,
            nalUnitHeaderLength: 4, // AVCC format
            formatDescriptionOut: &_formatDescription
        )

        guard status == noErr, let formatDesc = _formatDescription else {
            LogManager.shared.log("VideoDecoder: Failed to create format description \(status)")
            return
        }

        // Detect dimension changes (orientation switch) — recreate session like scrcpy does
        var needsNewSession = (decompressionSession == nil)
        if let oldFormat = self.formatDescription, decompressionSession != nil {
            let oldDim = CMVideoFormatDescriptionGetDimensions(oldFormat)
            let newDim = CMVideoFormatDescriptionGetDimensions(formatDesc)
            if oldDim.width != newDim.width || oldDim.height != newDim.height {
                LogManager.shared.log("VideoDecoder: Dimensions changed \(oldDim.width)x\(oldDim.height) -> \(newDim.width)x\(newDim.height), recreating session")
                VTDecompressionSessionInvalidate(decompressionSession!)
                decompressionSession = nil
                timeOffset = 0 // Reset time sync for new stream
                needsNewSession = true
            }
        }

        self.formatDescription = formatDesc

        // Create Decompression Session
        if needsNewSession {
            let decoderSpecification: [String: Any] = [:]

            // Enable RealTime playback hint
            let destinationImageBufferAttributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferOpenGLCompatibilityKey as String: true
            ]

            var outputCallback = VTDecompressionOutputCallbackRecord(
                decompressionOutputCallback: decompressionCallback,
                decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
            )

            var _session: VTDecompressionSession?
            let sessionStatus = VTDecompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                formatDescription: formatDesc,
                decoderSpecification: decoderSpecification as CFDictionary,
                imageBufferAttributes: destinationImageBufferAttributes as CFDictionary,
                outputCallback: &outputCallback,
                decompressionSessionOut: &_session
            )

            if sessionStatus == noErr, let session = _session {
                self.decompressionSession = session
                VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
                LogManager.shared.log("VideoDecoder: Decompression Session Created Successfully")
                DispatchQueue.main.async { self.decoderState = "Session Ready" }
            } else {
                LogManager.shared.log("VideoDecoder: Failed to create decompression session \(sessionStatus)")
                DispatchQueue.main.async { self.decoderState = "Session Failure: \(sessionStatus)" }
            }
        }
    }
    
    private func decodeFrame(data: Data, ptsNanos: UInt64) {
        guard let session = decompressionSession else {
            LogManager.shared.log("VideoDecoder: No session to decode frame")
            return
        }
        
        // Create BlockBuffer
        var blockBuffer: CMBlockBuffer?
        // FORCE COPY to ensure contiguous memory and valid base address. Slices are dangerous here.
        let nalData = Data(data) 
        
        let status = nalData.withUnsafeBytes { bufferPointer in
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: nalData.count,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: nalData.count,
                flags: kCMBlockBufferAssureMemoryNowFlag,
                blockBufferOut: &blockBuffer
            )
        }
        
        guard status == noErr, let buffer = blockBuffer else {
            LogManager.shared.log("VideoDecoder: BlockBuffer creation failed \(status)")
            return
        }
        
        // Copy data safely
        nalData.withUnsafeBytes { rawBufferPointer in
            if let address = rawBufferPointer.baseAddress {
                 CMBlockBufferReplaceDataBytes(with: address, blockBuffer: buffer, offsetIntoDestination: 0, dataLength: nalData.count)
            } else {
                 LogManager.shared.log("VideoDecoder: FAILED to get raw address for NAL data")
            }
        }
        
        // Create Sample Buffer
        var sampleBuffer: CMSampleBuffer?
        let sampleSizeArray = [nalData.count]
        
             // Time Synchronization logic
             // We need to map Sender PTS -> Receiver Host Time
             // Strategy: Maintain a moving average of the offset OR just latch on the first frame.
             // Simple Latch with buffering:
             
             if self.timeOffset == 0 {
                 let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
                 let senderTime = Double(ptsNanos) / 1_000_000_000.0
                 // Offset = CurrentReceiverTime - SenderTime
                 // But we want to play it slightly in the future (De-jitter buffer)
                 // PlayTime = SenderTime + Offset + Buffering
                 // => PlayTime = SenderTime + (Now - SenderTime) + 0.05
                 // => PlayTime = Now + 0.05
                 self.timeOffset = now - senderTime
                 LogManager.shared.log("VideoDecoder: Synced Timebase. Offset: \(self.timeOffset), Buffering: 50ms")
             }
             
             // Old Sender-based PTS (unused)
             // let senderTime = Double(ptsNanos) / 1_000_000_000.0
             // let presentationTimeSeconds = senderTime + self.timeOffset + 0.050
             // let presentationTime = CMTime(seconds: presentationTimeSeconds, preferredTimescale: 1_000_000_000)
             
             
             // Ensure monotonic? If jitter is wild, we might get frames out of order.
             // But we only want to ensure we don't present *before* the previous frame.
             
             // DEBUG: Log the calculated time to see if strictly monotonic / valid
             // LogManager.shared.log("PTS Debug: Nanos: \(ptsNanosSafe), Offset: \(self.timeOffset), PTime: \(presentationTime.seconds)")
             
             // SMOOTHNESS IMPLEMENTATION (v47)
             // Use Arrival Time + Jitter Buffer (50ms)
             // We ignore the Sender PTS for synchronization to avoid clock drift/offset issues.
             // We rely on the Receiver's HostTime clock which aligns with the Renderer's Timebase.
             
             let hostTime = CMClockGetTime(CMClockGetHostTimeClock())
             let presentationTime = CMTimeAdd(hostTime, CMTime(seconds: 0.05, preferredTimescale: 1_000_000_000))
             
             var timing = CMSampleTimingInfo(
                 duration: CMTime.invalid,
                 presentationTimeStamp: presentationTime,
                 decodeTimeStamp: .invalid
             )
        
             let sbStatus = CMSampleBufferCreateReady(
              allocator: kCFAllocatorDefault,
              dataBuffer: buffer,
              formatDescription: formatDescription,
              sampleCount: 1,
              sampleTimingEntryCount: 1, // ENABLE TIMING
              sampleTimingArray: &timing, // PASS TIMING
              sampleSizeEntryCount: 1,
              sampleSizeArray: sampleSizeArray,
              sampleBufferOut: &sampleBuffer
          )
          
          if sbStatus == noErr, let sb = sampleBuffer {
              // REMOVE DisplayImmediately to allow Layer to schedule based on PTS
              // Note: We need to ensure the key is NOT present, checking if it defaults to false.
              // Logic: If we DON'T set it to true, it respects the timestamp.
              // BUT, earlier code might have set it? No, we create the array here or get it.
              // Only if we EXPLICITLY set it to True does it bypass.
              // So we just DO NOT set it.
              
              // However, let's explicitly remove it if it exists (unlikely in fresh buffer)
              // or just don't add it.




             // Asynchronous Decode
             let flags: VTDecodeFrameFlags = [._EnableAsynchronousDecompression, ._EnableTemporalProcessing]
             var infoFlags: VTDecodeInfoFlags = []
             
             let status = VTDecompressionSessionDecodeFrame(
                 session,
                 sampleBuffer: sb,
                 flags: flags,
                 frameRefcon: nil,
                 infoFlagsOut: &infoFlags
             )
             
             if status != noErr {
                 LogManager.shared.log("VideoDecoder: Decode Frame Failed \(status)")
             } else {
                 // LogManager.shared.log("VideoDecoder: Frame Submitted")
             }
         } else {
             LogManager.shared.log("VideoDecoder: Failed to create SampleBuffer \(sbStatus)")
         }
    }
}

private func decompressionCallback(
    decompressionOutputRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTDecodeInfoFlags,
    imageBuffer: CVImageBuffer?,
    presentationTimeStamp: CMTime,
    presentationDuration: CMTime
) {
    guard status == noErr, let imageBuffer = imageBuffer, let refCon = decompressionOutputRefCon else { return }
    let decoder = Unmanaged<VideoDecoder>.fromOpaque(refCon).takeUnretainedValue()
    
    // Create SampleBuffer again from ImageBuffer for the display layer
    // Actually AVSampleBufferDisplayLayer prefers CMSampleBuffer.
    
    var sampleBuffer: CMSampleBuffer?
    var timing = CMSampleTimingInfo(duration: presentationDuration, presentationTimeStamp: presentationTimeStamp, decodeTimeStamp: .invalid)
    
    var formatDesc: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: imageBuffer, formatDescriptionOut: &formatDesc)
    
    guard let desc = formatDesc else { return }
    
    CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: imageBuffer,
        formatDescription: desc,
        sampleTiming: &timing,
        sampleBufferOut: &sampleBuffer
    )
    
    if let sb = sampleBuffer {
        // LogManager.shared.log("VideoDecoder: Frame Decoded Successfully. Dispatching to Renderer.")
        DispatchQueue.main.async {
            decoder.decodedFrameCount += 1
            // decoder.decoderState = "Decoding: \(decoder.decodedFrameCount)" // Removed for Production
            decoder.delegate?.didDecode(sampleBuffer: sb)
        }
    } else {
        LogManager.shared.log("VideoDecoder: Failed to create CMSampleBuffer from ImageBuffer")
    }
}
