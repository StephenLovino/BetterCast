#include "VideoEncoderFF.h"
#include <QDebug>
#include <QElapsedTimer>
#include <cstring>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
}

#ifndef FF_PROFILE_H264_HIGH
#define FF_PROFILE_H264_HIGH 100
#endif

VideoEncoderFF::VideoEncoderFF(QObject* parent)
    : QObject(parent)
{
}

VideoEncoderFF::~VideoEncoderFF() {
    shutdown();
}

bool VideoEncoderFF::tryEncoder(const char* codecName, int width, int height, int fps, int bitrate) {
    const AVCodec* codec = avcodec_find_encoder_by_name(codecName);
    if (!codec) return false;

    AVCodecContext* ctx = avcodec_alloc_context3(codec);
    if (!ctx) return false;

    ctx->width = width;
    ctx->height = height;
    ctx->time_base = {1, fps};
    ctx->framerate = {fps, 1};
    ctx->pix_fmt = AV_PIX_FMT_NV12;
    ctx->bit_rate = bitrate;
    ctx->rc_max_rate = bitrate * 3 / 2;              // allow 1.5x peak for motion
    ctx->rc_buffer_size = bitrate;                     // 1-second VBV buffer
    ctx->gop_size = fps * 5;                           // keyframe every 5 seconds
    ctx->max_b_frames = 0;                             // no B-frames for low latency
    ctx->flags |= AV_CODEC_FLAG_LOW_DELAY;
    ctx->thread_count = 0;                             // auto — let FFmpeg pick
    ctx->profile = FF_PROFILE_H264_HIGH;

    // Low-latency tuning per encoder
    if (strcmp(codecName, "libx264") == 0) {
        av_opt_set(ctx->priv_data, "preset", "veryfast", 0);  // better quality than ultrafast
        av_opt_set(ctx->priv_data, "tune", "zerolatency", 0);
        av_opt_set(ctx->priv_data, "aq-mode", "2", 0);        // variance AQ — helps motion
    } else if (strstr(codecName, "nvenc")) {
        av_opt_set(ctx->priv_data, "preset", "p4", 0);        // balanced speed/quality
        av_opt_set(ctx->priv_data, "tune", "ull", 0);         // ultra-low-latency
        av_opt_set(ctx->priv_data, "zerolatency", "1", 0);
        av_opt_set(ctx->priv_data, "rc", "vbr", 0);           // VBR — better motion quality
        av_opt_set(ctx->priv_data, "spatial-aq", "1", 0);     // spatial adaptive quantization
        av_opt_set(ctx->priv_data, "temporal-aq", "1", 0);    // temporal adaptive quantization
        av_opt_set(ctx->priv_data, "rc-lookahead", "0", 0);   // no lookahead — low latency
    } else if (strstr(codecName, "amf")) {
        av_opt_set(ctx->priv_data, "usage", "ultralowlatency", 0);
        av_opt_set(ctx->priv_data, "rc", "vbr_peak", 0);      // VBR with peak constraint
        av_opt_set(ctx->priv_data, "quality", "balanced", 0);
        av_opt_set(ctx->priv_data, "vbaq", "1", 0);           // adaptive quantization
    } else if (strstr(codecName, "qsv")) {
        av_opt_set(ctx->priv_data, "preset", "veryfast", 0);
    } else if (strstr(codecName, "vaapi")) {
        // VAAPI: pixel format must be vaapi for HW surface
        // For simplicity, we upload NV12 frames — FFmpeg handles the rest
        // Note: VAAPI init requires a hw_device_ctx which we skip for now
    }

    int ret = avcodec_open2(ctx, codec, nullptr);
    if (ret < 0) {
        char errbuf[256];
        av_strerror(ret, errbuf, sizeof(errbuf));
        qDebug() << "Sender: Encoder" << codecName << "failed to open:" << errbuf;
        avcodec_free_context(&ctx);
        return false;
    }

    // Extract SPS/PPS from extradata if present
    if (ctx->extradata && ctx->extradata_size > 0) {
        // Parse AVCC extradata or Annex-B extradata for SPS/PPS
        const uint8_t* p = ctx->extradata;
        int remaining = ctx->extradata_size;

        while (remaining > 4) {
            // Look for Annex-B start codes
            if (p[0] == 0 && p[1] == 0 && p[2] == 0 && p[3] == 1) {
                p += 4;
                remaining -= 4;
                // Find end of this NALU
                const uint8_t* naluStart = p;
                while (remaining > 4 && !(p[0] == 0 && p[1] == 0 && p[2] == 0 && p[3] == 1)) {
                    p++; remaining--;
                }
                int naluLen = static_cast<int>(p - naluStart);
                uint8_t naluType = naluStart[0] & 0x1F;
                if (naluType == 7) { // SPS
                    m_sps = QByteArray(reinterpret_cast<const char*>(naluStart), naluLen);
                } else if (naluType == 8) { // PPS
                    m_pps = QByteArray(reinterpret_cast<const char*>(naluStart), naluLen);
                }
            } else {
                p++; remaining--;
            }
        }
    }

    m_ctx = ctx;
    m_encoderName = QString::fromUtf8(codecName);
    qDebug() << "Sender: Using encoder:" << codecName << "at" << width << "x" << height << "@" << fps;
    return true;
}

bool VideoEncoderFF::init(int width, int height, int fps, int bitrateMbps) {
    shutdown();
    m_fps = fps;
    int bitrate = bitrateMbps * 1000000;

    // Probe encoders in preference order
    const char* encoders[] = {
        "h264_nvenc",     // NVIDIA
        "h264_amf",       // AMD
        "h264_qsv",       // Intel QuickSync
        "h264_vaapi",     // Linux VA-API
        "libx264",        // Software fallback
        nullptr
    };

    for (int i = 0; encoders[i]; i++) {
        if (tryEncoder(encoders[i], width, height, fps, bitrate)) {
            break;
        }
    }

    if (!m_ctx) {
        emit error("No H.264 encoder available. Install FFmpeg with libx264.");
        return false;
    }

    m_frame = av_frame_alloc();
    m_frame->format = AV_PIX_FMT_NV12;
    m_frame->width = width;
    m_frame->height = height;
    if (av_frame_get_buffer(m_frame, 32) < 0) {
        emit error("Failed to allocate encoder frame buffer");
        shutdown();
        return false;
    }

    m_pkt = av_packet_alloc();
    m_frameCount = 0;
    m_forceKeyframe = false;
    return true;
}

QByteArray VideoEncoderFF::annexBtoAVCC(const uint8_t* data, int size) {
    // Convert Annex-B (start codes: 00 00 00 01 or 00 00 01) to AVCC (4-byte BE length prefix)
    QByteArray result;
    result.reserve(size);

    int i = 0;
    while (i < size) {
        // Find start code
        int scLen = 0;
        if (i + 3 < size && data[i] == 0 && data[i+1] == 0 && data[i+2] == 0 && data[i+3] == 1) {
            scLen = 4;
        } else if (i + 2 < size && data[i] == 0 && data[i+1] == 0 && data[i+2] == 1) {
            scLen = 3;
        } else {
            i++;
            continue;
        }

        int naluStart = i + scLen;

        // Find next start code or end of data
        int naluEnd = size;
        for (int j = naluStart; j < size - 3; j++) {
            if (data[j] == 0 && data[j+1] == 0 &&
                (data[j+2] == 1 || (data[j+2] == 0 && j + 3 < size && data[j+3] == 1))) {
                naluEnd = j;
                break;
            }
        }

        int naluLen = naluEnd - naluStart;
        if (naluLen > 0) {
            // Cache SPS/PPS from stream
            uint8_t naluType = data[naluStart] & 0x1F;
            if (naluType == 7) {
                m_sps = QByteArray(reinterpret_cast<const char*>(data + naluStart), naluLen);
            } else if (naluType == 8) {
                m_pps = QByteArray(reinterpret_cast<const char*>(data + naluStart), naluLen);
            }

            // Write 4-byte big-endian length + NALU data
            uint8_t lenBuf[4];
            lenBuf[0] = (naluLen >> 24) & 0xFF;
            lenBuf[1] = (naluLen >> 16) & 0xFF;
            lenBuf[2] = (naluLen >> 8) & 0xFF;
            lenBuf[3] = naluLen & 0xFF;
            result.append(reinterpret_cast<const char*>(lenBuf), 4);
            result.append(reinterpret_cast<const char*>(data + naluStart), naluLen);
        }

        i = naluEnd;
    }

    return result;
}

void VideoEncoderFF::encode(const QByteArray& nv12Data, int width, int height) {
    if (!m_ctx || !m_frame || !m_pkt) return;
    if (width != m_ctx->width || height != m_ctx->height) {
        qWarning() << "Sender: Frame size mismatch, reinitializing encoder";
        init(width, height, m_fps);
        if (!m_ctx) return;
    }

    av_frame_make_writable(m_frame);

    // Copy NV12 data into AVFrame
    int ySize = width * height;
    const uint8_t* src = reinterpret_cast<const uint8_t*>(nv12Data.constData());

    // Y plane
    for (int y = 0; y < height; y++) {
        memcpy(m_frame->data[0] + y * m_frame->linesize[0], src + y * width, width);
    }
    // UV plane
    const uint8_t* uvSrc = src + ySize;
    for (int y = 0; y < height / 2; y++) {
        memcpy(m_frame->data[1] + y * m_frame->linesize[1], uvSrc + y * width, width);
    }

    m_frame->pts = m_frameCount++;

    if (m_forceKeyframe) {
        m_frame->pict_type = AV_PICTURE_TYPE_I;
        m_frame->flags |= AV_FRAME_FLAG_KEY;
        m_forceKeyframe = false;
    } else {
        m_frame->pict_type = AV_PICTURE_TYPE_NONE;
        m_frame->flags &= ~AV_FRAME_FLAG_KEY;
    }

    int ret = avcodec_send_frame(m_ctx, m_frame);
    if (ret < 0) {
        char errbuf[256];
        av_strerror(ret, errbuf, sizeof(errbuf));
        qWarning() << "Sender: avcodec_send_frame failed:" << errbuf;
        return;
    }

    while (ret >= 0) {
        ret = avcodec_receive_packet(m_ctx, m_pkt);
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) break;
        if (ret < 0) break;

        // Build BetterCast video payload: [8B PTS nanoseconds][AVCC NALUs]
        // PTS in nanoseconds: frame_pts * (1e9 / fps)
        uint64_t ptsNanos = static_cast<uint64_t>(m_pkt->pts) * (1000000000ULL / m_fps);

        QByteArray payload;
        payload.reserve(8 + m_pkt->size + 64);

        // 8-byte PTS (written as raw bytes — receiver reads as uint64)
        payload.append(reinterpret_cast<const char*>(&ptsNanos), 8);

        // Check if this is a keyframe — prepend cached SPS/PPS
        bool isKeyframe = (m_pkt->flags & AV_PKT_FLAG_KEY);
        if (isKeyframe && !m_sps.isEmpty() && !m_pps.isEmpty()) {
            // SPS as AVCC NALU
            int spsLen = m_sps.size();
            uint8_t lenBuf[4];
            lenBuf[0] = (spsLen >> 24) & 0xFF;
            lenBuf[1] = (spsLen >> 16) & 0xFF;
            lenBuf[2] = (spsLen >> 8) & 0xFF;
            lenBuf[3] = spsLen & 0xFF;
            payload.append(reinterpret_cast<const char*>(lenBuf), 4);
            payload.append(m_sps);

            // PPS as AVCC NALU
            int ppsLen = m_pps.size();
            lenBuf[0] = (ppsLen >> 24) & 0xFF;
            lenBuf[1] = (ppsLen >> 16) & 0xFF;
            lenBuf[2] = (ppsLen >> 8) & 0xFF;
            lenBuf[3] = ppsLen & 0xFF;
            payload.append(reinterpret_cast<const char*>(lenBuf), 4);
            payload.append(m_pps);
        }

        // Convert packet data from Annex-B to AVCC and append
        QByteArray avccData = annexBtoAVCC(m_pkt->data, m_pkt->size);
        payload.append(avccData);

        emit encoded(payload);
        av_packet_unref(m_pkt);
    }
}

void VideoEncoderFF::requestKeyframe() {
    m_forceKeyframe = true;
}

void VideoEncoderFF::shutdown() {
    if (m_pkt) { av_packet_free(&m_pkt); m_pkt = nullptr; }
    if (m_frame) { av_frame_free(&m_frame); m_frame = nullptr; }
    if (m_ctx) { avcodec_free_context(&m_ctx); m_ctx = nullptr; }
    m_sps.clear();
    m_pps.clear();
    m_frameCount = 0;
    m_encoderName.clear();
}
