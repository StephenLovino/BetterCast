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
    private var formatDescription: CMVideoFormatDescription?
    
    // NALU buffer management
    private var sps: Data?
    private var pps: Data?
    
    init() {
        LogManager.shared.log("VideoDecoder: Initialized")
    }
    
    func decode(data: Data) {
        // LogManager.shared.log("VideoDecoder: Decoding \(data.count) bytes")
        
        // Scan for SPS/PPS in the received data (which might contain multiple NALUs)
        var offset = 0
        let totalLen = data.count
        
        while offset + 4 <= totalLen {
            let lenBuf = data.subdata(in: offset..<offset+4)
            let naluLen = Int(UInt32(bigEndian: lenBuf.withUnsafeBytes { $0.load(as: UInt32.self) }))
            
            if offset + 4 + naluLen > totalLen { break }
            
            let naluHeader = data[offset + 4]
            let naluType = naluHeader & 0x1F
            
            if naluType == 7 { // SPS
                // LogManager.shared.log("VideoDecoder: Found SPS (\(naluLen) bytes)")
                sps = data.subdata(in: offset+4 ..< offset+4+naluLen)
            } else if naluType == 8 { // PPS
                // LogManager.shared.log("VideoDecoder: Found PPS (\(naluLen) bytes)")
                pps = data.subdata(in: offset+4 ..< offset+4+naluLen)
            }
            
            offset += 4 + naluLen
        }
        
        // Try to initialize session if we found new headers
        createDecompressionSessionIfReady()
        
        if decompressionSession != nil {
            decodeFrame(data: data)
        } else {
             // Only log this if we truly are stuck
             // LogManager.shared.log("VideoDecoder: Waiting for SPS/PPS...")
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
        
        self.formatDescription = formatDesc
        
        // Create Decompression Session
        if decompressionSession == nil {
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
    
    private func decodeFrame(data: Data) {
        guard let session = decompressionSession else {
            LogManager.shared.log("VideoDecoder: No session to decode frame")
            return
        }
        
        // Create BlockBuffer
        // Create BlockBuffer
        var blockBuffer: CMBlockBuffer?
        // Data is already [AVCC Len][NALU], which is what we need.
        let nalData = data
        
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
        
        // Copy data into block buffer (since we used CreateWithMemoryBlock with nil memoryBlock, it allocated memory, we need to fill it?
        // Wait, better to use CMBlockBufferCreateWithMemoryBlock passing the pointer, but keeping validity is hard.
        // Let's use CMBlockBufferReplaceDataBytes.
        CMBlockBufferReplaceDataBytes(with: nalData.withUnsafeBytes { $0.baseAddress! }, blockBuffer: buffer, offsetIntoDestination: 0, dataLength: nalData.count)
        
        // Create Sample Buffer
        var sampleBuffer: CMSampleBuffer?
        let sampleSizeArray = [nalData.count]
        
            let sbStatus = CMSampleBufferCreateReady(
             allocator: kCFAllocatorDefault,
             dataBuffer: buffer,
             formatDescription: formatDescription,
             sampleCount: 1,
             sampleTimingEntryCount: 0,
             sampleTimingArray: nil,
             sampleSizeEntryCount: 1,
             sampleSizeArray: sampleSizeArray,
             sampleBufferOut: &sampleBuffer
         )
         
         if sbStatus == noErr, let sb = sampleBuffer {
             // Force display immediately
             let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true) as? [[CFString: Any]]
             if let _ = attachments {
                 let dict = CFArrayGetValueAtIndex(CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true), 0)
                 let dictRef = unsafeBitCast(dict, to: CFMutableDictionary.self)
                 CFDictionarySetValue(dictRef, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
             }

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
