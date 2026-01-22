import Foundation
import VideoToolbox
import CoreMedia

protocol VideoEncoderDelegate: AnyObject {
    func videoEncoder(_ encoder: VideoEncoder, didEncode data: Data)
}

class VideoEncoder {
    weak var delegate: VideoEncoderDelegate?
    private var compressionSession: VTCompressionSession?
    private var frameCount = 0
    private let bitrate: Int
    
    // Cache for headers so we can re-send them if needed
    private var cachedSPS: Data?
    private var cachedPPS: Data?
    
    init(width: Int, height: Int, bitrate: Int = 20_000_000) {
        self.bitrate = bitrate
        
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
        // Allow bursts up to 2x average (or untethered for Ultra)
        let limitCF = [bitrate * 2, 1] as CFArray
        
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrateCF)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limitCF)
        
        // Strict Keyframe Control
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 60 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 1.0 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse) // Crucial for Real-Time
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 60 as CFNumber)

        VTCompressionSessionPrepareToEncodeFrames(session)
        LogManager.shared.log("VideoEncoder: Initialized (v41 - Dynamic Bitrate: \(bitrate/1_000_000)Mbps)")
    }
    
    func encode(sampleBuffer: CMSampleBuffer) {
        guard let session = compressionSession,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        let presentationTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        
        frameCount += 1
        var frameProperties: [String: Any] = [:]
        
        // Force keyframe every 60 frames (approx 1s) to ensure recovery
        // The first frame (Frame 1) is forced to be a Keyframe to jumpstart the stream.
        if frameCount == 1 || frameCount % 60 == 0 {
             LogManager.shared.log("VideoEncoder: Forcing Keyframe request (Frame \(frameCount))")
             frameProperties[kVTEncodeFrameOptionKey_ForceKeyFrame as String] = kCFBooleanTrue
        }
        
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: imageBuffer,
            presentationTimeStamp: presentationTimestamp,
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
            LogManager.shared.log("VideoEncoder: Keyframe Encoded! Bundling Headers.")
            
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
        
        // 4. Send One Megapacket
        if !coalescedData.isEmpty {
             delegate?.videoEncoder(self, didEncode: coalescedData)
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
