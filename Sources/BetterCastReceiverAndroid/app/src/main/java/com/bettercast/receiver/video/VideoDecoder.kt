package com.bettercast.receiver.video

import android.media.MediaCodec
import android.media.MediaCodecList
import android.media.MediaFormat
import android.util.Log
import android.view.Surface
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
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
        private const val MIME_AVC = "video/avc"
        private const val MIME_HEVC = "video/hevc"
        private const val INPUT_DEQUEUE_TIMEOUT_US = 8_000L
    }

    private data class FrameData(val annexB: ByteArray, val ptsUs: Long)

    private var codec: MediaCodec? = null
    private var surface: Surface? = null
    private var isConfigured = false
    @Volatile private var isStarted = false

    private var cachedSps: ByteArray? = null
    private var cachedPps: ByteArray? = null
    /// HEVC only — no H.264 equivalent.
    private var cachedVps: ByteArray? = null

    /**
     * Which codec the sender is using, sniffed from the stream.
     *
     * Deliberately detected rather than negotiated, so an older sender keeps working and
     * no handshake change is needed. HEVC's VPS (type 32) has no H.264 counterpart, and
     * the two type encodings — (b >> 1) & 0x3F for HEVC, b & 0x1F for H.264 — do not
     * collide across the parameter-set values we test.
     */
    private var streamIsHevc: Boolean? = null

    private var framesDecoded: Long = 0
    private var framesRendered: Long = 0
    private var framesDropped: Long = 0
    private var lastStatsTime: Long = 0

    // Decoder dwell measurement: time from queueInputBuffer to dequeueOutputBuffer per PTS.
    // This is the number that tells us whether low-latency mode is actually working.
    private val feedTimesNs = java.util.concurrent.ConcurrentHashMap<Long, Long>()
    private var dwellSumMs: Double = 0.0
    private var dwellMaxMs: Double = 0.0
    private var dwellCount: Long = 0

    var onKeyframeNeeded: (() -> Unit)? = null

    /**
     * Decoded picture size, published once the codec reports its output format.
     *
     * The UI needs this to size the surface to the stream's aspect ratio. Without it
     * the surface is whatever shape the phone is and MediaCodec stretches the picture
     * to fit, so a 16:10 Mac desktop arrives distorted on a 20:9 panel.
     */
    private val _videoSize = MutableStateFlow<Pair<Int, Int>?>(null)
    val videoSize: StateFlow<Pair<Int, Int>?> = _videoSize.asStateFlow()

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

        // Sniff the codec from any parameter set in this frame — every time, not once.
        // This decision used to be cached for the life of the process, so a receiver that
        // had already shown an H.264 session kept parsing a later H.265 one with H.264
        // rules: NAL types misread, nothing recognised as a parameter set, garbage fed to
        // an AVC decoder. It presents as a black screen with "fed=1093 rendered=0" — the
        // decoder accepting input and emitting nothing.
        var detected: Boolean? = null
        for (n in nalus) {
            if (n.isEmpty()) continue
            val header = n[0].toInt() and 0xFF
            val hevcType = (header shr 1) and 0x3F
            val avcType = header and 0x1F
            // Key on bytes that exist in only one codec. 0x40 is an HEVC VPS and means
            // nothing in H.264. Do NOT treat HEVC types 33/34 as proof by themselves:
            // an ordinary H.264 P-slice with header 0x41 reads as HEVC type 32 under
            // the HEVC rule, and detecting on it would flap the codec mid-stream.
            if (header == 0x40) { detected = true; break }
            if (avcType == 7 && hevcType !in 32..34) { detected = false; break }
        }
        if (detected != null && detected != streamIsHevc) {
            if (streamIsHevc == null) {
                Log.i(TAG, "Stream codec detected: ${if (detected) "H.265" else "H.264"}")
            } else {
                Log.i(TAG, "Stream codec changed to ${if (detected) "H.265" else "H.264"} — reconfiguring")
                stop()
                cachedVps = null
                cachedSps = null
                cachedPps = null
            }
            streamIsHevc = detected
        }

        // Nothing decodable until a parameter set has identified the codec.
        val hevc = streamIsHevc ?: return

        var sps: ByteArray? = null
        var pps: ByteArray? = null
        var vps: ByteArray? = null
        val frameNalus = mutableListOf<ByteArray>()

        for (nalu in nalus) {
            if (nalu.isEmpty()) continue
            if (hevc) {
                when (val t = (nalu[0].toInt() shr 1) and 0x3F) {
                    32 -> { vps = nalu; cachedVps = nalu }
                    33 -> { sps = nalu; cachedSps = nalu }
                    34 -> { pps = nalu; cachedPps = nalu }
                    else -> if (t <= 31) frameNalus.add(nalu)   // VCL NAL units
                }
            } else {
                when (nalu[0].toInt() and 0x1F) {
                    7 -> { sps = nalu; cachedSps = nalu }
                    8 -> { pps = nalu; cachedPps = nalu }
                    5 -> frameNalus.add(nalu)
                    in 1..3 -> frameNalus.add(nalu)
                }
            }
        }

        val haveParams = cachedSps != null && cachedPps != null && (!hevc || cachedVps != null)
        if (!isConfigured && haveParams && surface != null) {
            configureCodec(cachedSps!!, cachedPps!!)
        }

        if (isStarted && frameNalus.isNotEmpty()) {
            val prefix = listOfNotNull(vps, sps, pps)
            frameQueue.put(FrameData(toAnnexB(prefix, frameNalus), ptsUs))
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

    /** Prefix NALs (parameter sets, when present on this frame) then the picture NALs. */
    private fun toAnnexB(prefix: List<ByteArray>, frameNalus: List<ByteArray>): ByteArray {
        val startCode = byteArrayOf(0x00, 0x00, 0x00, 0x01)
        var totalSize = 0
        for (n in prefix) totalSize += 4 + n.size
        for (n in frameNalus) totalSize += 4 + n.size

        val result = ByteArray(totalSize)
        var offset = 0
        for (n in prefix + frameNalus) {
            System.arraycopy(startCode, 0, result, offset, 4); offset += 4
            System.arraycopy(n, 0, result, offset, n.size); offset += n.size
        }
        return result
    }

    private fun configureCodec(sps: ByteArray, pps: ByteArray) {
        // Release any previous instance first. Reconfiguring without this leaks one
        // MediaCodec per attempt, and the codec pool is small — a handful of
        // reconnects or surface changes exhausts it and start() then fails with
        // NO_MEMORY, leaving the decoder permanently unable to come up.
        stop()

        var decoder: MediaCodec? = null
        try {
            // Size the format from the stream's own SPS. A fixed 1920x1080 here is what
            // made anything larger fail to come up at all — the Windows sender captures
            // the monitor or virtual display at its native size, so 1440p and 4K are
            // routine, while the Mac sender happened to stay at or below 1080p.
            val hevc = streamIsHevc == true
            val mime = if (hevc) MIME_HEVC else MIME_AVC
            // SpsParser reads H.264 only. HEVC's SPS is a different structure, so fall
            // back to the last known picture size (or 1080p) and let the codec correct
            // itself from csd-0 — MediaCodec reports the real size in its output format,
            // which publishVideoSize already picks up.
            val dims = if (hevc) {
                _videoSize.value?.let { SpsParser.Dimensions(it.first, it.second) }
            } else {
                SpsParser.parse(sps)
            }
            val codedWidth = dims?.width ?: 1920
            val codedHeight = dims?.height ?: 1080
            if (dims == null) {
                Log.w(TAG, "Could not read size from SPS; assuming ${codedWidth}x$codedHeight")
            } else {
                Log.i(TAG, "SPS reports ${codedWidth}x$codedHeight")
            }
            val format = MediaFormat.createVideoFormat(mime, codedWidth, codedHeight)

            val startCode = byteArrayOf(0x00, 0x00, 0x00, 0x01)
            if (hevc) {
                // HEVC wants one csd-0 holding VPS, SPS and PPS back to back — not the
                // csd-0/csd-1 split H.264 uses. Getting this wrong is a silent failure:
                // configure() succeeds and no picture ever appears.
                val vps = cachedVps ?: ByteArray(0)
                val csd = ByteBuffer.allocate(12 + vps.size + sps.size + pps.size)
                if (vps.isNotEmpty()) { csd.put(startCode); csd.put(vps) }
                csd.put(startCode); csd.put(sps)
                csd.put(startCode); csd.put(pps)
                csd.flip()
                format.setByteBuffer("csd-0", csd)
            } else {
                val csd0 = ByteBuffer.allocate(4 + sps.size)
                csd0.put(startCode); csd0.put(sps); csd0.flip()
                format.setByteBuffer("csd-0", csd0)

                val csd1 = ByteBuffer.allocate(4 + pps.size)
                csd1.put(startCode); csd1.put(pps); csd1.flip()
                format.setByteBuffer("csd-1", csd1)
            }

            // Keyframes scale with resolution, and a frame larger than the input buffer
            // is dropped outright in feedDataToDecoder — at 1440p/4K a fixed 1MB ceiling
            // throws away exactly the IDR the decoder is waiting for, so the picture
            // never starts. Half a luma plane is comfortably above any real keyframe.
            format.setInteger(
                MediaFormat.KEY_MAX_INPUT_SIZE,
                maxOf(1_000_000, codedWidth * codedHeight / 2)
            )
            format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            format.setInteger(MediaFormat.KEY_PRIORITY, 0)
            format.setInteger("vendor.low-latency.enable", 1)
            // Qualcomm's actual vendor key (the generic one above is a no-op on QTI parts).
            // Same set Moonlight uses for game-streaming latency.
            format.setInteger("vendor.qti-ext-dec-low-latency.enable", 1)
            // Output frames in DECODE order, skipping the H.264 reorder buffer. Our encoder
            // sends no B-frames, but the SPS doesn't advertise zero reordering, so the
            // decoder reserves ~4 frames of DPB "just in case" — measured as ~130ms dwell.
            // Decode order == display order for this stream. Same key Moonlight uses.
            format.setInteger("vendor.qti-ext-dec-picture-order.enable", 1)
            // Hint the codec to run unthrottled instead of pacing to the nominal frame rate.
            // Cloud-gaming/RTC apps use this to shave decoder dwell time on Qualcomm parts.
            format.setInteger(MediaFormat.KEY_OPERATING_RATE, Short.MAX_VALUE.toInt())

            // Prefer a dedicated low-latency hardware decoder when the vendor ships one
            // (e.g. c2.qti.avc.decoder.low_latency on Qualcomm). createDecoderByType picks
            // the regular variant, which buffers 2-4 frames internally.
            val lowLatencyName = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.firstOrNull {
                !it.isEncoder &&
                it.name.endsWith(".low_latency") && !it.name.contains(".secure") &&
                it.supportedTypes.any { t -> t.equals(mime, ignoreCase = true) }
            }?.name

            decoder = if (lowLatencyName != null) {
                Log.i(TAG, "Using low-latency decoder: $lowLatencyName")
                MediaCodec.createByCodecName(lowLatencyName)
            } else {
                Log.i(TAG, "No low-latency decoder variant; using default for $mime")
                MediaCodec.createDecoderByType(mime)
            }
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
            // The instance exists even when configure/start throws. Without releasing
            // it here, every failure permanently consumes a codec slot — which is how
            // a single bad attempt snowballs into NO_MEMORY on all later ones.
            try { decoder?.release() } catch (_: Exception) {}
            codec = null
            isConfigured = false
            isStarted = false
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
                            feedTimesNs.remove(bufferInfo.presentationTimeUs)?.let { fedAt ->
                                val ms = (System.nanoTime() - fedAt) / 1e6
                                dwellSumMs += ms
                                if (ms > dwellMaxMs) dwellMaxMs = ms
                                dwellCount++
                            }
                            decoder.releaseOutputBuffer(outputIndex, true)
                            framesRendered++
                            lastRenderNs = System.nanoTime()
                        }
                        outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                            Log.d(TAG, "Output format changed: ${decoder.outputFormat}")
                            publishVideoSize(decoder.outputFormat)
                        }
                    }

                    val now = System.currentTimeMillis()
                    if (now - lastStatsTime >= 5000) {
                        val dwellAvg = if (dwellCount > 0) dwellSumMs / dwellCount else 0.0
                        Log.d(TAG, "Stats: fed=$framesDecoded rendered=$framesRendered dropped=$framesDropped queued=${frameQueue.size} " +
                                "dwellAvg=${"%.1f".format(dwellAvg)}ms dwellMax=${"%.1f".format(dwellMaxMs)}ms (n=$dwellCount)")
                        dwellSumMs = 0.0; dwellMaxMs = 0.0; dwellCount = 0
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

    /**
     * Read the real picture size out of the output format.
     *
     * KEY_WIDTH/KEY_HEIGHT are the padded, macroblock-aligned buffer dimensions —
     * 1080 rounds up to 1088 on plenty of decoders. The crop rectangle is the part
     * that is actually meant to be shown, so prefer it when present, or the aspect
     * ratio comes out slightly wrong and the picture sits a few pixels off.
     */
    private fun publishVideoSize(format: MediaFormat) {
        try {
            val hasCrop = format.containsKey("crop-left") && format.containsKey("crop-right") &&
                    format.containsKey("crop-top") && format.containsKey("crop-bottom")
            val width = if (hasCrop) {
                format.getInteger("crop-right") - format.getInteger("crop-left") + 1
            } else {
                format.getInteger(MediaFormat.KEY_WIDTH)
            }
            val height = if (hasCrop) {
                format.getInteger("crop-bottom") - format.getInteger("crop-top") + 1
            } else {
                format.getInteger(MediaFormat.KEY_HEIGHT)
            }
            if (width > 0 && height > 0) {
                _videoSize.value = width to height
                Log.i(TAG, "Video size ${width}x$height")
            }
        } catch (e: Exception) {
            Log.w(TAG, "Could not read video size from output format", e)
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
            if (feedTimesNs.size > 256) feedTimesNs.clear() // bound the map if outputs stall
            feedTimesNs[ptsUs] = System.nanoTime()
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
        cachedVps = null
        streamIsHevc = null
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
