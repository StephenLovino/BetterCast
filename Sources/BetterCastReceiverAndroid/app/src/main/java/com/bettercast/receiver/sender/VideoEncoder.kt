package com.bettercast.receiver.sender

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Bundle
import android.util.Log
import android.view.Surface
import kotlinx.coroutines.*
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

class VideoEncoder(
    val width: Int = 1280,
    val height: Int = 720,
    private val bitrate: Int = 8_000_000,
    private val fps: Int = 30,
    private val keyframeIntervalSec: Int = 5
) {
    companion object {
        private const val TAG = "VideoEncoder"
        private const val MIME_TYPE = "video/avc"
    }

    var inputSurface: Surface? = null
        private set

    var onEncodedFrame: ((ByteArray) -> Unit)? = null

    private var codec: MediaCodec? = null
    private var cachedSps: ByteArray? = null
    private var cachedPps: ByteArray? = null
    private var drainJob: Job? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var frameCount = 0L

    fun start() {
        val format = MediaFormat.createVideoFormat(MIME_TYPE, width, height).apply {
            setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
            setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, keyframeIntervalSec)
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            // Low latency hints
            try {
                setInteger(MediaFormat.KEY_LATENCY, 0)
                setInteger(MediaFormat.KEY_PRIORITY, 0)
            } catch (_: Exception) {
                // Not all devices support these keys
            }
        }

        val encoder = MediaCodec.createEncoderByType(MIME_TYPE)
        encoder.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        inputSurface = encoder.createInputSurface()
        encoder.start()
        codec = encoder

        Log.i(TAG, "Encoder started: ${width}x${height} @ ${bitrate / 1_000_000}Mbps, ${fps}fps")
        startDrainLoop()
    }

    fun forceKeyframe() {
        try {
            val params = Bundle()
            params.putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
            codec?.setParameters(params)
            Log.d(TAG, "Keyframe requested")
        } catch (e: Exception) {
            Log.w(TAG, "Failed to request keyframe", e)
        }
    }

    private fun startDrainLoop() {
        drainJob = scope.launch(Dispatchers.IO) {
            val bufferInfo = MediaCodec.BufferInfo()
            val encoder = codec ?: return@launch

            while (isActive) {
                val index = try {
                    encoder.dequeueOutputBuffer(bufferInfo, 10_000)
                } catch (e: Exception) {
                    if (isActive) Log.e(TAG, "dequeueOutputBuffer error", e)
                    break
                }

                when {
                    index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val format = encoder.outputFormat
                        cachedSps = extractNaluFromCsd(format.getByteBuffer("csd-0"))
                        cachedPps = extractNaluFromCsd(format.getByteBuffer("csd-1"))
                        Log.i(TAG, "Format changed — SPS: ${cachedSps?.size} bytes, PPS: ${cachedPps?.size} bytes")
                    }

                    index >= 0 -> {
                        // Skip codec config buffers (SPS/PPS already extracted via format change)
                        if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                            encoder.releaseOutputBuffer(index, false)
                            continue
                        }

                        val outputBuffer = encoder.getOutputBuffer(index)
                        if (outputBuffer != null) {
                            val isKeyframe = bufferInfo.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0
                            val ptsUs = bufferInfo.presentationTimeUs

                            val annexBData = ByteArray(bufferInfo.size)
                            outputBuffer.position(bufferInfo.offset)
                            outputBuffer.get(annexBData)

                            val packet = buildAvccPacket(annexBData, ptsUs, isKeyframe)
                            if (packet != null) {
                                frameCount++
                                if (frameCount <= 5 || frameCount % 300 == 0L) {
                                    Log.i(TAG, "Encoded frame #$frameCount: ${packet.size} bytes${if (isKeyframe) " [KEYFRAME]" else ""}")
                                }
                                onEncodedFrame?.invoke(packet)
                            }
                        }

                        encoder.releaseOutputBuffer(index, false)
                    }
                }
            }
        }
    }

    /**
     * Extract raw NALU bytes from a CSD ByteBuffer (strips Annex-B start code).
     */
    private fun extractNaluFromCsd(csd: ByteBuffer?): ByteArray? {
        if (csd == null) return null
        val data = ByteArray(csd.remaining())
        csd.get(data)
        csd.rewind()

        // Strip leading start code (00 00 00 01 or 00 00 01)
        val offset = when {
            data.size >= 4 && data[0] == 0.toByte() && data[1] == 0.toByte()
                    && data[2] == 0.toByte() && data[3] == 1.toByte() -> 4
            data.size >= 3 && data[0] == 0.toByte() && data[1] == 0.toByte()
                    && data[2] == 1.toByte() -> 3
            else -> 0
        }
        return data.copyOfRange(offset, data.size)
    }

    /**
     * Convert Annex-B encoded frame to AVCC megapacket format:
     * [8-byte PTS little-endian nanos][4-byte BE NALU len][NALU data]...
     *
     * Keyframes get SPS + PPS prepended.
     */
    private fun buildAvccPacket(annexBData: ByteArray, ptsUs: Long, isKeyframe: Boolean): ByteArray? {
        val ptsNanos = ptsUs * 1000 // microseconds -> nanoseconds
        val nalus = parseAnnexBNalus(annexBData)
        if (nalus.isEmpty()) return null

        val avccPayload = ByteArrayOutputStream()

        // Prepend cached SPS + PPS on keyframes
        if (isKeyframe && cachedSps != null && cachedPps != null) {
            writeAvccNalu(avccPayload, cachedSps!!)
            writeAvccNalu(avccPayload, cachedPps!!)
        }

        for (nalu in nalus) {
            if (nalu.isEmpty()) continue
            val naluType = nalu[0].toInt() and 0x1F
            // Skip inline SPS/PPS — we prepend cached versions on keyframes
            if (naluType == 7 || naluType == 8) continue
            writeAvccNalu(avccPayload, nalu)
        }

        // Build final packet: [8-byte PTS][AVCC NALUs]
        val payload = avccPayload.toByteArray()
        val result = ByteBuffer.allocate(8 + payload.size)
        result.order(ByteOrder.LITTLE_ENDIAN)
        result.putLong(ptsNanos)
        result.put(payload)
        return result.array()
    }

    private fun writeAvccNalu(out: ByteArrayOutputStream, nalu: ByteArray) {
        // 4-byte big-endian length prefix + NALU data
        val len = ByteBuffer.allocate(4).order(ByteOrder.BIG_ENDIAN).putInt(nalu.size).array()
        out.write(len)
        out.write(nalu)
    }

    /**
     * Parse Annex-B stream into individual NALUs.
     * Handles both 3-byte (00 00 01) and 4-byte (00 00 00 01) start codes.
     */
    private fun parseAnnexBNalus(data: ByteArray): List<ByteArray> {
        val nalus = mutableListOf<ByteArray>()
        var i = 0
        var naluStart = -1

        while (i < data.size) {
            // Check for 4-byte start code
            if (i + 3 < data.size &&
                data[i] == 0.toByte() && data[i + 1] == 0.toByte() &&
                data[i + 2] == 0.toByte() && data[i + 3] == 1.toByte()
            ) {
                if (naluStart >= 0) {
                    nalus.add(data.copyOfRange(naluStart, i))
                }
                i += 4
                naluStart = i
            }
            // Check for 3-byte start code
            else if (i + 2 < data.size &&
                data[i] == 0.toByte() && data[i + 1] == 0.toByte() &&
                data[i + 2] == 1.toByte()
            ) {
                if (naluStart >= 0) {
                    nalus.add(data.copyOfRange(naluStart, i))
                }
                i += 3
                naluStart = i
            } else {
                i++
            }
        }

        // Last NALU
        if (naluStart >= 0 && naluStart < data.size) {
            nalus.add(data.copyOfRange(naluStart, data.size))
        }

        return nalus
    }

    fun stop() {
        drainJob?.cancel()
        drainJob = null

        try {
            codec?.stop()
            codec?.release()
        } catch (e: Exception) {
            Log.w(TAG, "Error stopping encoder", e)
        }
        codec = null
        inputSurface = null
        cachedSps = null
        cachedPps = null
        frameCount = 0
        Log.i(TAG, "Encoder stopped")
    }

    fun destroy() {
        stop()
        scope.cancel()
    }
}
