package com.bettercast.receiver.video

import android.media.MediaCodec
import android.media.MediaFormat
import android.util.Log
import android.view.Surface
import kotlinx.coroutines.*
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * Low-latency H.264 decoder using ordered queue buffer (scrcpy-style).
 *
 * Network thread enqueues every frame — no encoded frames are ever dropped,
 * preserving the H.264 reference chain over bursty WiFi connections.
 * Decoder thread takes frames in order and feeds them to MediaCodec.
 * Output thread renders decoded frames immediately (latest wins at display).
 */
class VideoDecoder {

    companion object {
        private const val TAG = "VideoDecoder"
        private const val MIME_TYPE = "video/avc"
        private const val INPUT_DEQUEUE_TIMEOUT_US = 8_000L
    }

    private data class FrameData(val annexB: ByteArray, val ptsUs: Long)

    private var codec: MediaCodec? = null
    private var surface: Surface? = null
    private var isConfigured = false
    @Volatile private var isStarted = false

    private var cachedSps: ByteArray? = null
    private var cachedPps: ByteArray? = null

    private var framesDecoded: Long = 0
    private var framesRendered: Long = 0
    private var framesDropped: Long = 0
    private var lastStatsTime: Long = 0

    var onKeyframeNeeded: (() -> Unit)? = null

    private val frameQueue = LinkedBlockingQueue<FrameData>()
    private var decoderJob: Job? = null
    private var drainJob: Job? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    @Volatile private var lastRenderNs: Long = 0

    fun setSurface(surface: Surface?) {
        val oldSurface = this.surface
        this.surface = surface
        if (surface != null && cachedSps != null && cachedPps != null && !isConfigured) {
            configureCodec(cachedSps!!, cachedPps!!)
            // IDR frame likely arrived before surface was ready — request new one
            onKeyframeNeeded?.invoke()
        } else if (surface != null && isConfigured && isStarted && codec != null && surface !== oldSurface) {
            // Surface changed (e.g. orientation flip) — switch codec output surface
            try {
                codec?.setOutputSurface(surface)
                Log.d(TAG, "Switched codec output to new surface")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to switch surface, resetting codec", e)
                stop()
                configureCodec(cachedSps!!, cachedPps!!)
                onKeyframeNeeded?.invoke()
            }
        }
    }

    private var receiveCount = 0L

    fun onFrameData(frameData: ByteArray) {
        receiveCount++
        if (frameData.size < 12) {
            Log.w(TAG, "Frame too small: ${frameData.size} bytes")
            return
        }

        if (receiveCount <= 5 || receiveCount % 300 == 0L) {
            Log.i(TAG, "onFrameData #$receiveCount: ${frameData.size} bytes, configured=$isConfigured started=$isStarted surface=${surface != null}")
        }

        val ptsNs = ByteBuffer.wrap(frameData, 0, 8).order(ByteOrder.LITTLE_ENDIAN).long
        val ptsUs = ptsNs / 1000

        val naluData = frameData.copyOfRange(8, frameData.size)
        processNaluData(naluData, ptsUs)
    }

    private fun processNaluData(data: ByteArray, ptsUs: Long) {
        val nalus = parseNalus(data)
        if (nalus.isEmpty()) return

        var sps: ByteArray? = null
        var pps: ByteArray? = null
        val frameNalus = mutableListOf<ByteArray>()

        for (nalu in nalus) {
            if (nalu.isEmpty()) continue
            val naluType = nalu[0].toInt() and 0x1F

            when (naluType) {
                7 -> { sps = nalu; cachedSps = nalu }
                8 -> { pps = nalu; cachedPps = nalu }
                5 -> { frameNalus.add(nalu) }
                in 1..3 -> { frameNalus.add(nalu) }
            }
        }

        if (!isConfigured && cachedSps != null && cachedPps != null && surface != null) {
            configureCodec(cachedSps!!, cachedPps!!)
        }

        if (isStarted && frameNalus.isNotEmpty()) {
            val annexBData = toAnnexB(sps, pps, frameNalus)
            frameQueue.put(FrameData(annexBData, ptsUs))
        }
    }

    private fun parseNalus(data: ByteArray): List<ByteArray> {
        val nalus = mutableListOf<ByteArray>()
        var offset = 0

        while (offset + 4 <= data.size) {
            val length = ByteBuffer.wrap(data, offset, 4).order(ByteOrder.BIG_ENDIAN).int
            offset += 4
            if (length <= 0 || offset + length > data.size) break
            val nalu = data.copyOfRange(offset, offset + length)
            nalus.add(nalu)
            offset += length
        }

        return nalus
    }

    private fun toAnnexB(sps: ByteArray?, pps: ByteArray?, frameNalus: List<ByteArray>): ByteArray {
        val startCode = byteArrayOf(0x00, 0x00, 0x00, 0x01)
        var totalSize = 0

        if (sps != null) totalSize += 4 + sps.size
        if (pps != null) totalSize += 4 + pps.size
        for (nalu in frameNalus) totalSize += 4 + nalu.size

        val result = ByteArray(totalSize)
        var offset = 0

        if (sps != null) {
            System.arraycopy(startCode, 0, result, offset, 4); offset += 4
            System.arraycopy(sps, 0, result, offset, sps.size); offset += sps.size
        }
        if (pps != null) {
            System.arraycopy(startCode, 0, result, offset, 4); offset += 4
            System.arraycopy(pps, 0, result, offset, pps.size); offset += pps.size
        }
        for (nalu in frameNalus) {
            System.arraycopy(startCode, 0, result, offset, 4); offset += 4
            System.arraycopy(nalu, 0, result, offset, nalu.size); offset += nalu.size
        }

        return result
    }

    private fun configureCodec(sps: ByteArray, pps: ByteArray) {
        try {
            val format = MediaFormat.createVideoFormat(MIME_TYPE, 1920, 1080)

            val startCode = byteArrayOf(0x00, 0x00, 0x00, 0x01)
            val csd0 = ByteBuffer.allocate(4 + sps.size)
            csd0.put(startCode); csd0.put(sps); csd0.flip()
            format.setByteBuffer("csd-0", csd0)

            val csd1 = ByteBuffer.allocate(4 + pps.size)
            csd1.put(startCode); csd1.put(pps); csd1.flip()
            format.setByteBuffer("csd-1", csd1)

            format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 1_000_000)
            format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            format.setInteger(MediaFormat.KEY_PRIORITY, 0)
            format.setInteger("vendor.low-latency.enable", 1)

            val decoder = MediaCodec.createDecoderByType(MIME_TYPE)
            decoder.configure(format, surface, null, 0)
            decoder.start()

            codec = decoder
            isConfigured = true
            isStarted = true
            lastRenderNs = 0

            Log.d(TAG, "Codec configured and started")
            startDecoderLoop()
            startDrainLoop()
        } catch (e: Exception) {
            Log.e(TAG, "Failed to configure codec", e)
            isConfigured = false
            isStarted = false
        }
    }

    private fun startDecoderLoop() {
        decoderJob?.cancel()
        val decoder = codec ?: return

        // Input thread: takes frames in order from queue and feeds to MediaCodec.
        // Blocking take() means no polling, no dropped frames — matches scrcpy's approach.
        decoderJob = scope.launch(Dispatchers.IO) {
            while (isActive && isStarted) {
                val frame = frameQueue.poll(10, TimeUnit.MILLISECONDS) ?: continue
                feedDataToDecoder(decoder, frame.annexB, frame.ptsUs)
            }
        }
    }

    private fun startDrainLoop() {
        drainJob?.cancel()
        lastStatsTime = System.currentTimeMillis()
        framesDecoded = 0
        framesRendered = 0
        framesDropped = 0

        val decoder = codec ?: return

        // Output thread: renders decoded frames immediately
        drainJob = scope.launch {
            val bufferInfo = MediaCodec.BufferInfo()
            while (isActive && isStarted) {
                try {
                    val outputIndex = decoder.dequeueOutputBuffer(bufferInfo, 8_000)
                    when {
                        outputIndex >= 0 -> {
                            decoder.releaseOutputBuffer(outputIndex, true)
                            framesRendered++
                            lastRenderNs = System.nanoTime()
                        }
                        outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                            Log.d(TAG, "Output format changed: ${decoder.outputFormat}")
                        }
                    }

                    val now = System.currentTimeMillis()
                    if (now - lastStatsTime >= 5000) {
                        Log.d(TAG, "Stats: fed=$framesDecoded rendered=$framesRendered dropped=$framesDropped queued=${frameQueue.size}")
                        lastStatsTime = now
                    }
                } catch (e: MediaCodec.CodecException) {
                    Log.e(TAG, "Codec error in drain loop", e)
                    if (!e.isRecoverable) { resetCodec(); break }
                } catch (e: Exception) {
                    if (isActive) Log.e(TAG, "Drain loop error", e)
                }
            }
        }
    }

    private fun feedDataToDecoder(decoder: MediaCodec, data: ByteArray, ptsUs: Long) {
        val inputIndex = decoder.dequeueInputBuffer(INPUT_DEQUEUE_TIMEOUT_US)
        if (inputIndex >= 0) {
            val inputBuffer = decoder.getInputBuffer(inputIndex) ?: return
            inputBuffer.clear()

            if (data.size > inputBuffer.capacity()) {
                Log.w(TAG, "Frame too large: ${data.size} > ${inputBuffer.capacity()}")
                decoder.queueInputBuffer(inputIndex, 0, 0, 0, 0)
                framesDropped++
                return
            }

            inputBuffer.put(data)
            decoder.queueInputBuffer(inputIndex, 0, data.size, ptsUs, 0)
            framesDecoded++
        } else {
            framesDropped++
            if (framesDropped % 30 == 0L) {
                Log.w(TAG, "No input buffer available (dropped frame, size=${data.size})")
            }
        }
    }

    private var lastKeyframeRequestTime: Long = 0

    fun requestKeyframeIfNeeded() {
        val now = System.currentTimeMillis()
        if (now - lastKeyframeRequestTime > 500) {
            lastKeyframeRequestTime = now
            onKeyframeNeeded?.invoke()
        }
    }

    private fun resetCodec() {
        Log.d(TAG, "Resetting codec")
        stop()
        isConfigured = false
        cachedSps = null
        cachedPps = null
        onKeyframeNeeded?.invoke()
    }

    fun stop() {
        isStarted = false
        isConfigured = false
        decoderJob?.cancel()
        decoderJob = null
        drainJob?.cancel()
        drainJob = null
        frameQueue.clear()

        try {
            codec?.stop()
            codec?.release()
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping codec", e)
        }
        codec = null
        lastRenderNs = 0
    }

    fun destroy() {
        stop()
        scope.cancel()
    }
}
