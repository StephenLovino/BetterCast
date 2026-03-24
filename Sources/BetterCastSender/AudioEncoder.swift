import Foundation
import AVFoundation
import AudioToolbox
import CoreMedia

protocol AudioEncoderDelegate: AnyObject {
    func audioEncoder(_ encoder: AudioEncoder, didEncode data: Data, for connectionId: UUID)
}

class AudioEncoder {
    weak var delegate: AudioEncoderDelegate?
    let connectionId: UUID

    private var converter: AudioConverterRef?
    private var aacBuffer = Data()
    private var inputFormat: AudioStreamBasicDescription?
    private var outputFormat: AudioStreamBasicDescription?
    private var frameCount = 0

    init(connectionId: UUID) {
        self.connectionId = connectionId
    }

    func encode(sampleBuffer: CMSampleBuffer) {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee
        guard let srcFormat = asbd else { return }

        // Initialize converter on first audio frame
        if converter == nil {
            setupConverter(sourceFormat: srcFormat)
        }

        guard let converter = converter else { return }

        // Get PCM data from the sample buffer
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var lengthAtOffset: Int = 0
        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?

        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0,
                                                  lengthAtOffsetOut: &lengthAtOffset,
                                                  totalLengthOut: &totalLength,
                                                  dataPointerOut: &dataPointer)
        guard status == kCMBlockBufferNoErr, let pcmData = dataPointer else { return }

        // Store PCM for the converter callback
        pendingPCM = Data(bytes: pcmData, count: totalLength)
        pendingPCMFormat = srcFormat
        pendingPCMOffset = 0

        // Prepare output buffer for AAC
        let outputBufferSize: UInt32 = 8192
        let outputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(outputBufferSize))
        defer { outputBuffer.deallocate() }

        let outBuffer = AudioBuffer(
            mNumberChannels: min(srcFormat.mChannelsPerFrame, 2),
            mDataByteSize: outputBufferSize,
            mData: UnsafeMutableRawPointer(outputBuffer)
        )
        var outBufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: outBuffer)

        var ioOutputDataPacketSize: UInt32 = 1 // 1 AAC packet

        let convertStatus = AudioConverterFillComplexBuffer(
            converter,
            { (_, ioNumberDataPackets, ioData, outDataPacketDescription, inUserData) -> OSStatus in
                guard let userData = inUserData else {
                    ioNumberDataPackets.pointee = 0
                    return -1
                }
                let encoder = Unmanaged<AudioEncoder>.fromOpaque(userData).takeUnretainedValue()
                return encoder.provideInputData(ioNumberDataPackets: ioNumberDataPackets,
                                                 ioData: ioData,
                                                 outDataPacketDescription: outDataPacketDescription)
            },
            Unmanaged.passUnretained(self).toOpaque(),
            &ioOutputDataPacketSize,
            &outBufferList,
            nil
        )

        if convertStatus == noErr && outBufferList.mBuffers.mDataByteSize > 0 {
            let aacData = Data(bytes: outBufferList.mBuffers.mData!,
                              count: Int(outBufferList.mBuffers.mDataByteSize))

            frameCount += 1
            if frameCount % 100 == 1 {
                LogManager.shared.log("AudioEncoder: Encoded AAC packet \(frameCount), \(aacData.count) bytes")
            }

            delegate?.audioEncoder(self, didEncode: aacData, for: connectionId)
        }
    }

    // Input data provider for AudioConverter
    private var pendingPCM: Data?
    private var pendingPCMFormat: AudioStreamBasicDescription?
    private var pendingPCMOffset: Int = 0

    private func provideInputData(ioNumberDataPackets: UnsafeMutablePointer<UInt32>,
                                   ioData: UnsafeMutablePointer<AudioBufferList>,
                                   outDataPacketDescription: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?) -> OSStatus {
        guard let pcm = pendingPCM, pendingPCMOffset < pcm.count else {
            ioNumberDataPackets.pointee = 0
            return -1
        }

        let remaining = pcm.count - pendingPCMOffset
        pcm.withUnsafeBytes { rawBuffer in
            let ptr = rawBuffer.baseAddress!.advanced(by: pendingPCMOffset)
            ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: ptr)
            ioData.pointee.mBuffers.mDataByteSize = UInt32(remaining)
            ioData.pointee.mBuffers.mNumberChannels = pendingPCMFormat?.mChannelsPerFrame ?? 2
        }

        let bytesPerPacket = Int(pendingPCMFormat?.mBytesPerFrame ?? 4)
        let packets = remaining / bytesPerPacket
        ioNumberDataPackets.pointee = UInt32(packets)
        pendingPCMOffset = pcm.count // Mark as consumed

        return noErr
    }

    private func setupConverter(sourceFormat: AudioStreamBasicDescription) {
        var src = sourceFormat

        // Output: AAC-LC, same sample rate, stereo
        var dst = AudioStreamBasicDescription(
            mSampleRate: sourceFormat.mSampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: min(sourceFormat.mChannelsPerFrame, 2),
            mBitsPerChannel: 0,
            mReserved: 0
        )

        let status = AudioConverterNew(&src, &dst, &converter)
        if status != noErr {
            LogManager.shared.log("AudioEncoder: Failed to create AAC converter: \(status)")
            return
        }

        // Set bitrate: 128kbps stereo
        var bitrate: UInt32 = 128000
        AudioConverterSetProperty(converter!, kAudioConverterEncodeBitRate,
                                  UInt32(MemoryLayout<UInt32>.size), &bitrate)

        inputFormat = src
        outputFormat = dst

        LogManager.shared.log("AudioEncoder: Initialized AAC encoder (\(Int(src.mSampleRate))Hz, \(src.mChannelsPerFrame)ch → AAC 128kbps)")
    }

    deinit {
        if let converter = converter {
            AudioConverterDispose(converter)
        }
    }
}
