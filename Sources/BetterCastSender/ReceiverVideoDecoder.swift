import Foundation
import VideoToolbox
import CoreMedia

protocol ReceiverVideoDecoderDelegate: AnyObject {
    func didDecode(sampleBuffer: CMSampleBuffer)
}

class ReceiverVideoDecoder: ObservableObject {
    @Published var decoderState: String = "Waiting for Data..."
    @Published var decodedFrameCount: Int = 0

    weak var delegate: ReceiverVideoDecoderDelegate?
    private var decompressionSession: VTDecompressionSession?

    deinit {
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
        }
        LogManager.shared.log("ReceiverVideoDecoder: Deallocated")
    }

    private var formatDescription: CMVideoFormatDescription?

    private var sps: Data?
    private var pps: Data?

    private var timeOffset: Double = 0
    private var consecutiveErrors: Int = 0

    func decode(data: Data) {
        guard data.count > 8 else { return }

        let ptsData = data.prefix(8)

        var ptsNanos: UInt64 = 0
        let _ = Swift.withUnsafeMutableBytes(of: &ptsNanos) { ptr in
            ptsData.copyBytes(to: ptr)
        }

        let videoData = Data(data.dropFirst(8))

        var offset = 0
        let totalLen = videoData.count

        while offset + 4 <= totalLen {
            let lenBuf = videoData.subdata(in: offset..<offset+4)
            let naluLen = Int(UInt32(bigEndian: lenBuf.withUnsafeBytes { $0.load(as: UInt32.self) }))

            if offset + 4 + naluLen > totalLen { break }

            let naluHeader = videoData[offset + 4]
            let naluType = naluHeader & 0x1F

            if naluType == 7 {
                sps = videoData.subdata(in: offset+4 ..< offset+4+naluLen)
            } else if naluType == 8 {
                pps = videoData.subdata(in: offset+4 ..< offset+4+naluLen)
            }

            offset += 4 + naluLen
        }

        createDecompressionSessionIfReady()

        if decompressionSession != nil {
            decodeFrame(data: videoData, ptsNanos: ptsNanos)
        }
    }

    func reset() {
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
        }
        decompressionSession = nil
        formatDescription = nil
        sps = nil
        pps = nil
        timeOffset = 0
        DispatchQueue.main.async {
            self.decoderState = "Waiting for Data..."
            self.decodedFrameCount = 0
        }
    }

    private func createDecompressionSessionIfReady() {
        guard let sps = sps, let pps = pps else { return }

        let parameterSets = [sps, pps]
        let parameterSetPointers = parameterSets.map { ($0 as NSData).bytes.bindMemory(to: UInt8.self, capacity: $0.count) }
        let parameterSetSizes = parameterSets.map { $0.count }

        var _formatDescription: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: kCFAllocatorDefault,
            parameterSetCount: 2,
            parameterSetPointers: parameterSetPointers,
            parameterSetSizes: parameterSetSizes,
            nalUnitHeaderLength: 4,
            formatDescriptionOut: &_formatDescription
        )

        guard status == noErr, let formatDesc = _formatDescription else {
            LogManager.shared.log("ReceiverVideoDecoder: Failed to create format description \(status)")
            return
        }

        var needsNewSession = (decompressionSession == nil)
        if let oldFormat = self.formatDescription, decompressionSession != nil {
            let oldDim = CMVideoFormatDescriptionGetDimensions(oldFormat)
            let newDim = CMVideoFormatDescriptionGetDimensions(formatDesc)
            if oldDim.width != newDim.width || oldDim.height != newDim.height {
                LogManager.shared.log("ReceiverVideoDecoder: Dimensions changed \(oldDim.width)x\(oldDim.height) -> \(newDim.width)x\(newDim.height), recreating session")
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
                decompressionOutputCallback: receiverDecompressionCallback,
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
                LogManager.shared.log("ReceiverVideoDecoder: Session Created")
                DispatchQueue.main.async { self.decoderState = "Session Ready" }
            } else {
                LogManager.shared.log("ReceiverVideoDecoder: Failed to create session \(sessionStatus)")
                DispatchQueue.main.async { self.decoderState = "Session Failure: \(sessionStatus)" }
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
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: sampleSizeArray,
            sampleBufferOut: &sampleBuffer
        )

        if sbStatus == noErr, let sb = sampleBuffer {
            let flags: VTDecodeFrameFlags = [._EnableAsynchronousDecompression, ._EnableTemporalProcessing]
            var infoFlags: VTDecodeInfoFlags = []

            let decodeStatus = VTDecompressionSessionDecodeFrame(
                session,
                sampleBuffer: sb,
                flags: flags,
                frameRefcon: nil,
                infoFlagsOut: &infoFlags
            )

            if decodeStatus == -12916 { // kVTInvalidSessionErr
                // Session invalidated — clear it so it gets recreated on next keyframe
                VTDecompressionSessionInvalidate(session)
                decompressionSession = nil
                formatDescription = nil
                consecutiveErrors += 1
                if consecutiveErrors <= 3 {
                    LogManager.shared.log("ReceiverVideoDecoder: Session invalidated — waiting for next keyframe")
                }
            } else if decodeStatus != noErr {
                consecutiveErrors += 1
                if consecutiveErrors <= 3 {
                    LogManager.shared.log("ReceiverVideoDecoder: Decode Failed \(decodeStatus)")
                }
            } else {
                if consecutiveErrors > 3 {
                    LogManager.shared.log("ReceiverVideoDecoder: Recovered after \(consecutiveErrors) errors")
                }
                consecutiveErrors = 0
            }
        }
    }
}

private func receiverDecompressionCallback(
    decompressionOutputRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTDecodeInfoFlags,
    imageBuffer: CVImageBuffer?,
    presentationTimeStamp: CMTime,
    presentationDuration: CMTime
) {
    guard status == noErr, let imageBuffer = imageBuffer, let refCon = decompressionOutputRefCon else { return }
    let decoder = Unmanaged<ReceiverVideoDecoder>.fromOpaque(refCon).takeUnretainedValue()

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
            decoder.decodedFrameCount += 1
            decoder.delegate?.didDecode(sampleBuffer: sb)
        }
    }
}
