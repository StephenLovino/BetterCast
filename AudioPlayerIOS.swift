#if canImport(UIKit)
import Foundation
import AVFoundation
import AudioToolbox

/// Decodes raw AAC-LC frames and plays them via AVAudioEngine.
/// Expects raw AAC packets (no ADTS headers) as produced by BetterCast's AudioEncoder.
class AudioPlayerIOS {

    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var audioConverter: AudioConverterRef?

    fileprivate let outputSampleRate: Double = 48000
    fileprivate let outputChannels: UInt32 = 2

    private var outputFormat: AVAudioFormat?
    private var started = false

    // Shared state for the converter input callback
    fileprivate var currentPacketData: Data?
    fileprivate var currentPacketOffset: Int = 0
    fileprivate var packetDesc = AudioStreamPacketDescription()

    init() {
        setupEngine()
    }

    deinit {
        stop()
        if let converter = audioConverter {
            AudioConverterDispose(converter)
        }
    }

    // MARK: - Setup

    private func setupEngine() {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()

        engine.attach(player)

        guard let format = AVAudioFormat(standardFormatWithSampleRate: outputSampleRate, channels: AVAudioChannelCount(outputChannels)) else {
            LogManager.shared.log("AudioPlayer: Failed to create output format")
            return
        }

        outputFormat = format
        engine.connect(player, to: engine.mainMixerNode, format: format)

        self.audioEngine = engine
        self.playerNode = player
    }

    private func setupConverter() {
        if audioConverter != nil { return }

        // Input: AAC-LC
        var inputDesc = AudioStreamBasicDescription(
            mSampleRate: outputSampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: outputChannels,
            mBitsPerChannel: 0,
            mReserved: 0
        )

        // Output: PCM float32 interleaved
        var outputDesc = AudioStreamBasicDescription(
            mSampleRate: outputSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(outputChannels) * 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(outputChannels) * 4,
            mChannelsPerFrame: outputChannels,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var converter: AudioConverterRef?
        let status = AudioConverterNew(&inputDesc, &outputDesc, &converter)
        if status != noErr {
            LogManager.shared.log("AudioPlayer: Failed to create AudioConverter: \(status)")
            return
        }

        audioConverter = converter
        LogManager.shared.log("AudioPlayer: AAC decoder ready (48kHz stereo)")
    }

    private func startIfNeeded() {
        guard !started, let engine = audioEngine, let player = playerNode else { return }
        do {
            try engine.start()
            player.play()
            started = true
            LogManager.shared.log("AudioPlayer: Engine started")
        } catch {
            LogManager.shared.log("AudioPlayer: Engine start failed: \(error)")
        }
    }

    // MARK: - Public API

    func decode(aacData: Data) {
        setupConverter()
        startIfNeeded()

        guard let converter = audioConverter,
              let format = outputFormat else { return }

        // Store packet for converter callback
        currentPacketData = aacData
        currentPacketOffset = 0

        // Decode one AAC frame (1024 samples)
        let frameCount: UInt32 = 1024
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        pcmBuffer.frameLength = frameCount

        var outputDataPacketSize: UInt32 = frameCount
        let userData = Unmanaged.passUnretained(self).toOpaque()

        let status = AudioConverterFillComplexBuffer(
            converter,
            audioPlayerConverterInputCallback,
            userData,
            &outputDataPacketSize,
            pcmBuffer.mutableAudioBufferList,
            nil
        )

        currentPacketData = nil

        if status != noErr && status != 1 {
            AudioConverterReset(converter)
            return
        }

        if outputDataPacketSize > 0 {
            pcmBuffer.frameLength = outputDataPacketSize
            playerNode?.scheduleBuffer(pcmBuffer)
        }
    }

    func stop() {
        playerNode?.stop()
        audioEngine?.stop()
        started = false
    }
}

// MARK: - AudioConverter Input Callback (must be a free function)

private func audioPlayerConverterInputCallback(
    _ converter: AudioConverterRef,
    _ ioNumberDataPackets: UnsafeMutablePointer<UInt32>,
    _ ioData: UnsafeMutablePointer<AudioBufferList>,
    _ outDataPacketDescription: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
    _ inUserData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData = inUserData else {
        ioNumberDataPackets.pointee = 0
        return -1
    }

    let player = Unmanaged<AudioPlayerIOS>.fromOpaque(userData).takeUnretainedValue()

    guard let data = player.currentPacketData, player.currentPacketOffset < data.count else {
        ioNumberDataPackets.pointee = 0
        return 1
    }

    let remaining = data.count - player.currentPacketOffset

    data.withUnsafeBytes { rawBuffer in
        let ptr = rawBuffer.baseAddress!.advanced(by: player.currentPacketOffset)
        ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: ptr)
        ioData.pointee.mBuffers.mDataByteSize = UInt32(remaining)
        ioData.pointee.mBuffers.mNumberChannels = player.outputChannels
    }

    // Packet description for variable-bitrate AAC
    if let descPtr = outDataPacketDescription {
        player.packetDesc = AudioStreamPacketDescription(
            mStartOffset: 0,
            mVariableFramesInPacket: 0,
            mDataByteSize: UInt32(remaining)
        )
        descPtr.pointee = withUnsafeMutablePointer(to: &player.packetDesc) { $0 }
    }

    ioNumberDataPackets.pointee = 1
    player.currentPacketOffset = data.count
    return noErr
}
#endif
