package com.bettercast.receiver.video

/**
 * Minimal H.264 SPS reader — just enough to recover the coded picture size.
 *
 * MediaCodec is handed the SPS as `csd-0`, so in principle it could work the size out
 * itself, and most decoders do. Enough of them size their input buffers from the
 * dimensions passed to [android.media.MediaFormat.createVideoFormat] instead that
 * declaring a fixed 1920x1080 there quietly breaks every stream larger than that: the
 * Windows sender captures whatever the monitor or virtual display happens to be, which
 * is routinely 1440p or 4K, and the phone showed nothing while Mac and iOS were fine.
 *
 * Parsing is deliberately narrow. Anything unexpected returns null and the caller falls
 * back to the old fixed size, which is no worse than before.
 */
object SpsParser {

    data class Dimensions(val width: Int, val height: Int)

    /**
     * @param sps the SPS NAL unit *including* its one-byte NAL header.
     */
    fun parse(sps: ByteArray): Dimensions? {
        if (sps.size < 4) return null
        if ((sps[0].toInt() and 0x1F) != 7) return null

        return try {
            val rbsp = unescape(sps, 1)
            val r = BitReader(rbsp)

            val profileIdc = r.u(8)
            r.u(8)   // constraint flags + reserved
            r.u(8)   // level_idc
            r.ue()   // seq_parameter_set_id

            var chromaFormatIdc = 1
            var separateColourPlane = false
            if (profileIdc in intArrayOf(100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135)) {
                chromaFormatIdc = r.ue()
                if (chromaFormatIdc == 3) separateColourPlane = r.u(1) == 1
                r.ue()   // bit_depth_luma_minus8
                r.ue()   // bit_depth_chroma_minus8
                r.u(1)   // qpprime_y_zero_transform_bypass_flag
                if (r.u(1) == 1) {   // seq_scaling_matrix_present_flag
                    val lists = if (chromaFormatIdc != 3) 8 else 12
                    for (i in 0 until lists) {
                        if (r.u(1) == 1) skipScalingList(r, if (i < 6) 16 else 64)
                    }
                }
            }

            r.ue()   // log2_max_frame_num_minus4
            when (r.ue()) {   // pic_order_cnt_type
                0 -> r.ue()  // log2_max_pic_order_cnt_lsb_minus4
                1 -> {
                    r.u(1)   // delta_pic_order_always_zero_flag
                    r.se()   // offset_for_non_ref_pic
                    r.se()   // offset_for_top_to_bottom_field
                    val cycle = r.ue()
                    repeat(cycle) { r.se() }
                }
            }

            r.ue()   // max_num_ref_frames
            r.u(1)   // gaps_in_frame_num_value_allowed_flag

            val widthMbsMinus1 = r.ue()
            val heightMapUnitsMinus1 = r.ue()
            val frameMbsOnly = r.u(1)
            if (frameMbsOnly == 0) r.u(1)   // mb_adaptive_frame_field_flag
            r.u(1)   // direct_8x8_inference_flag

            var cropLeft = 0; var cropRight = 0; var cropTop = 0; var cropBottom = 0
            if (r.u(1) == 1) {   // frame_cropping_flag
                cropLeft = r.ue(); cropRight = r.ue(); cropTop = r.ue(); cropBottom = r.ue()
            }

            // Crop offsets are counted in chroma samples, so how many luma pixels each
            // one removes depends on the chroma sampling and on field coding.
            val subWidthC = if (chromaFormatIdc == 1 || chromaFormatIdc == 2) 2 else 1
            val subHeightC = if (chromaFormatIdc == 1) 2 else 1
            val mono = chromaFormatIdc == 0 || separateColourPlane
            val cropUnitX = if (mono) 1 else subWidthC
            val cropUnitY = (if (mono) 1 else subHeightC) * (2 - frameMbsOnly)

            val width = (widthMbsMinus1 + 1) * 16 - cropUnitX * (cropLeft + cropRight)
            val height = (2 - frameMbsOnly) * (heightMapUnitsMinus1 + 1) * 16 -
                    cropUnitY * (cropTop + cropBottom)

            if (width in 16..16384 && height in 16..16384) Dimensions(width, height) else null
        } catch (e: Exception) {
            null
        }
    }

    private fun skipScalingList(r: BitReader, size: Int) {
        var lastScale = 8
        var nextScale = 8
        for (i in 0 until size) {
            if (nextScale != 0) {
                val delta = r.se()
                nextScale = (lastScale + delta + 256) % 256
            }
            lastScale = if (nextScale == 0) lastScale else nextScale
        }
    }

    /** Strip H.264 emulation-prevention bytes (0x00 0x00 0x03 -> 0x00 0x00). */
    private fun unescape(data: ByteArray, from: Int): ByteArray {
        val out = ByteArray(data.size - from)
        var n = 0
        var zeros = 0
        var i = from
        while (i < data.size) {
            val b = data[i].toInt() and 0xFF
            if (zeros >= 2 && b == 0x03) {
                zeros = 0
                i++
                continue
            }
            zeros = if (b == 0x00) zeros + 1 else 0
            out[n++] = data[i]
            i++
        }
        return out.copyOf(n)
    }

    private class BitReader(private val data: ByteArray) {
        private var bitPos = 0

        fun u(bits: Int): Int {
            var v = 0
            repeat(bits) { v = (v shl 1) or readBit() }
            return v
        }

        /** Unsigned exp-Golomb. */
        fun ue(): Int {
            var leadingZeros = 0
            while (readBit() == 0) {
                leadingZeros++
                if (leadingZeros > 31) throw IllegalStateException("bad exp-golomb")
            }
            if (leadingZeros == 0) return 0
            return (1 shl leadingZeros) - 1 + u(leadingZeros)
        }

        /** Signed exp-Golomb. */
        fun se(): Int {
            val k = ue()
            val sign = if (k % 2 == 0) -1 else 1
            return sign * ((k + 1) / 2)
        }

        private fun readBit(): Int {
            val byteIndex = bitPos ushr 3
            if (byteIndex >= data.size) throw IndexOutOfBoundsException("sps overrun")
            val bit = (data[byteIndex].toInt() ushr (7 - (bitPos and 7))) and 1
            bitPos++
            return bit
        }
    }
}
