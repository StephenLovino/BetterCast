#if canImport(UIKit)
import Foundation
import VideoToolbox
import CoreMedia

protocol VideoDecoderDelegate: AnyObject {
    func didDecode(sampleBuffer: CMSampleBuffer)
}

class VideoDecoder {
    
    weak var delegate: VideoDecoderDelegate?
    private var decompressionSession: VTDecompressionSession?
    
    deinit {
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
        }
        LogManager.shared.log("VideoDecoder: Deallocated")
    }
    
    private var formatDescription: CMVideoFormatDescription?
    
    // NALU buffer management
    private var sps: Data?
    private var pps: Data?
    /// HEVC only — H.264 has no equivalent parameter set.
    private var vps: Data?
    /// Which codec the sender is using, sniffed from the stream's parameter sets.
    /// nil until the first one arrives; re-evaluated whenever one appears, because
    /// caching it for the life of the process is the bug that blanked the Android
    /// receiver when the sender switched codec mid-session.
    private var streamIsHevc: Bool?
    
    private var timeOffset: Double = 0
    
    func decode(data: Data) {
        // Expected format: [PTS: 8 bytes][NALUs...]
        guard data.count > 8 else { return }
        
        let ptsData = data.prefix(8)
        
        var ptsNanos: UInt64 = 0
        let _ = Swift.withUnsafeMutableBytes(of: &ptsNanos) { ptr in
            ptsData.copyBytes(to: ptr)
        }
        
        let videoData = Data(data.dropFirst(8))
        
        // Scan for SPS/PPS
        var offset = 0
        let totalLen = videoData.count
        
        while offset + 4 <= totalLen {
            let lenBuf = videoData.subdata(in: offset..<offset+4)
            let naluLen = Int(UInt32(bigEndian: lenBuf.withUnsafeBytes { $0.load(as: UInt32.self) }))
            
            if offset + 4 + naluLen > totalLen { break }
            
            let naluHeader = videoData[offset + 4]
            let h264Type = naluHeader & 0x1F
            let hevcType = (naluHeader >> 1) & 0x3F

            // Codec sniffing keyed on bytes that exist in only one codec. 0x40 is an
            // HEVC VPS and means nothing in H.264; an H.264 SPS (type 7) never collides
            // with an HEVC parameter set. Do NOT key on HEVC types 33/34 alone: an
            // ordinary H.264 P-slice with header 0x41 decodes as HEVC type 32 under the
            // HEVC rule, and switching on it would flap the codec mid-stream.
            if naluHeader == 0x40 {
                if streamIsHevc != true { switchCodec(hevc: true) }
            } else if h264Type == 7 && !(32...34).contains(hevcType) {
                if streamIsHevc != false { switchCodec(hevc: false) }
            }

            if streamIsHevc == true {
                if hevcType == 32 { vps = videoData.subdata(in: offset+4 ..< offset+4+naluLen) }
                else if hevcType == 33 { sps = videoData.subdata(in: offset+4 ..< offset+4+naluLen) }
                else if hevcType == 34 { pps = videoData.subdata(in: offset+4 ..< offset+4+naluLen) }
            } else if streamIsHevc == false {
                if h264Type == 7 { sps = videoData.subdata(in: offset+4 ..< offset+4+naluLen) }
                else if h264Type == 8 { pps = videoData.subdata(in: offset+4 ..< offset+4+naluLen) }
            }

            offset += 4 + naluLen
        }
        
        createDecompressionSessionIfReady()
        
        if decompressionSession != nil {
            decodeFrame(data: videoData, ptsNanos: ptsNanos)
        }
    }
    
    /// Tear everything down for a codec change so the new stream configures cleanly.
    private func switchCodec(hevc: Bool) {
        if streamIsHevc != nil {
            LogManager.shared.log("VideoDecoder: Stream codec changed to \(hevc ? "H.265" : "H.264") — reconfiguring")
        }
        streamIsHevc = hevc
        if let session = decompressionSession { VTDecompressionSessionInvalidate(session) }
        decompressionSession = nil
        formatDescription = nil
        vps = nil
        sps = nil
        pps = nil
    }

        private func createDecompressionSessionIfReady() {
        guard let sps = sps, let pps = pps else { return }
        let hevc = streamIsHevc == true
        // HEVC cannot configure without its VPS; H.264 has no such set.
        if hevc && vps == nil { return }

        let parameterSets = hevc ? [vps!, sps, pps] : [sps, pps]
        let parameterSetPointers = parameterSets.map { ($0 as NSData).bytes.bindMemory(to: UInt8.self, capacity: $0.count) }
        let parameterSetSizes = parameterSets.map { $0.count }

        var _formatDescription: CMFormatDescription?
        let status: OSStatus
        if hevc {
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: 3,
                parameterSetPointers: parameterSetPointers,
                parameterSetSizes: parameterSetSizes,
                nalUnitHeaderLength: 4,
                extensions: nil,
                formatDescriptionOut: &_formatDescription
            )
        } else {
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: 2,
                parameterSetPointers: parameterSetPointers,
                parameterSetSizes: parameterSetSizes,
                nalUnitHeaderLength: 4,
                formatDescriptionOut: &_formatDescription
            )
        }
        
        guard status == noErr, let formatDesc = _formatDescription else {
            LogManager.shared.log("VideoDecoder: Failed to create format description \(status)")
            return
        }
        
        // Detect dimension changes (orientation switch) — recreate session
        var needsNewSession = (decompressionSession == nil)
        if let oldFormat = self.formatDescription, decompressionSession != nil {
            let oldDim = CMVideoFormatDescriptionGetDimensions(oldFormat)
            let newDim = CMVideoFormatDescriptionGetDimensions(formatDesc)
            if oldDim.width != newDim.width || oldDim.height != newDim.height {
                LogManager.shared.log("VideoDecoder: Dimensions changed \(oldDim.width)x\(oldDim.height) -> \(newDim.width)x\(newDim.height), recreating session")
                VTDecompressionSessionInvalidate(decompressionSession!)
                decompressionSession = nil
                timeOffset = 0
                needsNewSession = true
            }
        }

        self.formatDescription = formatDesc

        if needsNewSession {
            let decoderSpecification: [String: Any] = [:]

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
                LogManager.shared.log("VideoDecoder: Session Ready")
            } else {
                LogManager.shared.log("VideoDecoder: Failed to create session \(sessionStatus)")
            }
        }
    }
    
    private func decodeFrame(data: Data, ptsNanos: UInt64) {
        guard let session = decompressionSession else { return }
        
        var blockBuffer: CMBlockBuffer?
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
        
        guard status == noErr, let buffer = blockBuffer else { return }
        
        nalData.withUnsafeBytes { rawBufferPointer in
            if let address = rawBufferPointer.baseAddress {
                 CMBlockBufferReplaceDataBytes(with: address, blockBuffer: buffer, offsetIntoDestination: 0, dataLength: nalData.count)
            }
        }
        
        var sampleBuffer: CMSampleBuffer?
        let sampleSizeArray = [nalData.count]
        
             // Time Synchronization logic (Mac Port)
             if self.timeOffset == 0 {
                 let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
                 let senderTime = Double(ptsNanos) / 1_000_000_000.0
                 self.timeOffset = now - senderTime
             }
             
             let hostTime = CMClockGetTime(CMClockGetHostTimeClock())
             // 16ms buffer = one frame at 60fps. Was 50ms — pure end-to-end latency we
             // don't need now that the encoder pipeline is stable.
             let presentationTime = CMTimeAdd(hostTime, CMTime(seconds: 0.016, preferredTimescale: 1_000_000_000))
             
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
              sampleTimingEntryCount: 1,
              sampleTimingArray: &timing,
              sampleSizeEntryCount: 1,
              sampleSizeArray: sampleSizeArray,
              sampleBufferOut: &sampleBuffer
          )
          
          if sbStatus == noErr, let sb = sampleBuffer {
             // Encoder uses AllowFrameReordering=false (no B-frames), so temporal
             // processing only adds reorder latency for nothing.
             let flags: VTDecodeFrameFlags = [._EnableAsynchronousDecompression]
             var infoFlags: VTDecodeInfoFlags = []
             
             let status = VTDecompressionSessionDecodeFrame(
                 session,
                 sampleBuffer: sb,
                 flags: flags,
                 frameRefcon: nil,
                 infoFlagsOut: &infoFlags
             )
             
             if status != noErr {
                 LogManager.shared.log("VideoDecoder: Decode Fail \(status)")
             }
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
        DispatchQueue.main.async {
            decoder.delegate?.didDecode(sampleBuffer: sb)
        }
    }
}
#endif
