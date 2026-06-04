package com.bettercast.receiver.audio

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.media.MediaCodec
import android.media.MediaFormat
import android.util.Log
import kotlinx.coroutines.*
import java.nio.ByteBuffer
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * Decodes raw AAC-LC frames (no ADTS) from BetterCast's sender and plays them via AudioTrack.
 *
 * Sender format (matches AudioEncoder.swift / AudioPlayerIOS.swift): 48 kHz stereo,
 * 1024-sample AAC-LC access units, no ADTS headers. Starts lazily on the first real audio
 * packet so nothing is allocated while the stream is silent (the sender emits ~6-byte silence
 * packets when there's no sound — those are skipped here).
 */
class AudioPlayer {

    companion object {
        private const val TAG = "AudioPlayer"
        private const val MIME = "audio/mp4a-latm"
        private const val SAMPLE_RATE = 48000
        private const val CHANNELS = 2
        // AudioSpecificConfig: AAC-LC (objType 2), 48 kHz (sampleRateIndex 3), stereo (config 2) → 0x11 0x90
        private val ASC = byteArrayOf(0x11.toByte(), 0x90.toByte())
        private const val DEQUEUE_TIMEOUT_US = 8_000L
        // Below this, a packet is an AAC silence/keepalive frame — skip it (also avoids
        // spinning up the codec/track just for silence). Matches the iOS receiver's guard.
        private const val MIN_AUDIO_BYTES = 10
        private const val AAC_SAMPLES_PER_FRAME = 1024L
    }

    private var codec: MediaCodec? = null
    private var audioTrack: AudioTrack? = null
    @Volatile private var isStarted = false

    private val frameQueue = LinkedBlockingQueue<ByteArray>()
    private var feedJob: Job? = null
    private var drainJob: Job? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    /** Feed one raw AAC packet (type byte already stripped by TcpClient). */
    fun onAudioData(aac: ByteArray) {
        if (aac.size < MIN_AUDIO_BYTES) return // silence / keepalive
        if (!isStarted) start()
        if (isStarted) frameQueue.put(aac)
    }

    @Synchronized
    private fun start() {
        if (isStarted) return
        try {
            val format = MediaFormat.createAudioFormat(MIME, SAMPLE_RATE, CHANNELS).apply {
                setByteBuffer("csd-0", ByteBuffer.wrap(ASC))
                setInteger(MediaFormat.KEY_IS_ADTS, 0)
            }
            val decoder = MediaCodec.createDecoderByType(MIME)
            decoder.configure(format, null, null, 0)
            decoder.start()
            codec = decoder

            val minBuf = AudioTrack.getMinBufferSize(
                SAMPLE_RATE,
                AudioFormat.CHANNEL_OUT_STEREO,
                AudioFormat.ENCODING_PCM_16BIT
            ).coerceAtLeast(8192)

            val track = AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                        .build()
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(SAMPLE_RATE)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                        .build()
                )
                .setBufferSizeInBytes(minBuf * 2)
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build()
            track.play()
            audioTrack = track

            isStarted = true
            startFeedLoop()
            startDrainLoop()
            Log.d(TAG, "AudioPlayer started (48 kHz stereo AAC-LC)")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start audio player", e)
            stop()
        }
    }

    private fun startFeedLoop() {
        val decoder = codec ?: return
        feedJob = scope.launch(Dispatchers.IO) {
            var ptsUs = 0L
            while (isActive && isStarted) {
                val frame = frameQueue.poll(10, TimeUnit.MILLISECONDS) ?: continue
                try {
                    val inIndex = decoder.dequeueInputBuffer(DEQUEUE_TIMEOUT_US)
                    if (inIndex >= 0) {
                        val buf = decoder.getInputBuffer(inIndex) ?: continue
                        buf.clear()
                        buf.put(frame)
                        decoder.queueInputBuffer(inIndex, 0, frame.size, ptsUs, 0)
                        ptsUs += AAC_SAMPLES_PER_FRAME * 1_000_000L / SAMPLE_RATE
                    }
                } catch (e: Exception) {
                    if (isActive) Log.e(TAG, "Audio feed error", e)
                }
            }
        }
    }

    private fun startDrainLoop() {
        val decoder = codec ?: return
        drainJob = scope.launch(Dispatchers.IO) {
            val info = MediaCodec.BufferInfo()
            while (isActive && isStarted) {
                try {
                    val outIndex = decoder.dequeueOutputBuffer(info, DEQUEUE_TIMEOUT_US)
                    if (outIndex >= 0) {
                        val out = decoder.getOutputBuffer(outIndex)
                        if (out != null && info.size > 0) {
                            val pcm = ByteArray(info.size)
                            out.position(info.offset)
                            out.get(pcm, 0, info.size)
                            audioTrack?.write(pcm, 0, pcm.size)
                        }
                        decoder.releaseOutputBuffer(outIndex, false)
                    }
                } catch (e: Exception) {
                    if (isActive) Log.e(TAG, "Audio drain error", e)
                }
            }
        }
    }

    fun stop() {
        isStarted = false
        feedJob?.cancel(); feedJob = null
        drainJob?.cancel(); drainJob = null
        frameQueue.clear()
        try { codec?.stop(); codec?.release() } catch (e: Exception) { Log.e(TAG, "codec stop", e) }
        codec = null
        try { audioTrack?.stop(); audioTrack?.release() } catch (e: Exception) { Log.e(TAG, "track stop", e) }
        audioTrack = null
    }

    fun destroy() {
        stop()
        scope.cancel()
    }
}
