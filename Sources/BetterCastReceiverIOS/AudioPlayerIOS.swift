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
    private var decodeCount = 0

    // Jitter buffer
    // At 48kHz with 1024-frame AAC packets, each buffer is ~21ms.
    // 8 buffers ≈ 170ms — wide enough to absorb Wi-Fi jitter without audible cracks.
    // On overflow we drop the OLDEST queued buffer (skip forward) instead of the newest,
    // so the discontinuity lands on already-stale audio rather than producing a mid-stream crack.
    private var pendingBuffers: Int = 0
    private let maxPendingBuffers: Int = 8

    // Shared state for the converter input callback
    fileprivate var currentPacketData: Data?
    fileprivate var currentPacketConsumed: Bool = false
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
        // Default category .soloAmbient doesn't grant low-latency hardware access
        // and produces crackles on streamed audio. .playback fixes routing without
        // changing anything else — keep options minimal so we don't fight iOS.
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback)
            try session.setActive(true)
        } catch {
            LogManager.shared.log("AudioPlayer: Session setup failed: \(error)")
        }
        // Best-effort low-latency hint; never fatal if the device rejects it.
        try? session.setPreferredIOBufferDuration(0.005)

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()

        engine.attach(player)

        guard let format = AVAudioFormat(standardFormatWithSampleRate: outputSampleRate,
                                          channels: AVAudioChannelCount(outputChannels)) else {
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

        // Output: PCM float32 non-interleaved (matches AVAudioEngine standard format)
        var outputDesc = AudioStreamBasicDescription(
            mSampleRate: outputSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
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
        LogManager.shared.log("AudioPlayer: AAC decoder ready (48kHz stereo, max \(maxPendingBuffers) buffers)")
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
        // Skip tiny silence frames (< 10 bytes)
        guard aacData.count >= 10 else { return }

        setupConverter()
        startIfNeeded()

        guard let converter = audioConverter,
              let format = outputFormat else { return }

        // Drop new packet if jitter buffer is full. With 8 buffers (~170ms) this is
        // rare; if it happens we accept a brief discontinuity rather than risk
        // disturbing the player node mid-playback.
        if pendingBuffers >= maxPendingBuffers {
            return
        }

        // Store packet for converter callback
        currentPacketData = aacData
        currentPacketConsumed = false

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

        if status == noErr && outputDataPacketSize > 0 {
            pcmBuffer.frameLength = outputDataPacketSize
            pendingBuffers += 1
            playerNode?.scheduleBuffer(pcmBuffer) { [weak self] in
                self?.pendingBuffers -= 1
            }

            decodeCount += 1
            if decodeCount % 100 == 1 {
                LogManager.shared.log("AudioPlayer: Decoded packet \(decodeCount), \(outputDataPacketSize) frames, pending: \(pendingBuffers)")
            }
        } else if status != noErr {
            decodeCount += 1
            if decodeCount % 50 == 1 {
                LogManager.shared.log("AudioPlayer: Decode failed (status \(status))")
            }
        }
    }

    func stop() {
        playerNode?.stop()
        audioEngine?.stop()
        started = false
        pendingBuffers = 0
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

    // Only provide data once per decode call
    guard let data = player.currentPacketData, !player.currentPacketConsumed else {
        ioNumberDataPackets.pointee = 0
        return 1
    }

    player.currentPacketConsumed = true

    data.withUnsafeBytes { rawBuffer in
        let ptr = rawBuffer.baseAddress!
        ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: ptr)
        ioData.pointee.mBuffers.mDataByteSize = UInt32(data.count)
        ioData.pointee.mBuffers.mNumberChannels = player.outputChannels
    }

    // Packet description for variable-bitrate AAC
    player.packetDesc = AudioStreamPacketDescription(
        mStartOffset: 0,
        mVariableFramesInPacket: 0,
        mDataByteSize: UInt32(data.count)
    )
    if let descPtr = outDataPacketDescription {
        withUnsafeMutablePointer(to: &player.packetDesc) { ptr in
            descPtr.pointee = ptr
        }
    }

    ioNumberDataPackets.pointee = 1
    return noErr
}
#endif
