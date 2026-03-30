#include "VideoDecoder.h"
#include <QDebug>
#include <QtEndian>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/imgutils.h>
}

VideoDecoder::VideoDecoder(QObject* parent)
    : QObject(parent)
{
}

VideoDecoder::~VideoDecoder() {
    destroyDecoder();
}

void VideoDecoder::decode(const QByteArray& data) {
    // Expected format: [PTS: 8 bytes][NALUs...]
    // PTS is uint64 native endian (matching Swift sender)
    if (data.size() <= 8) return;

    const uint8_t* raw = reinterpret_cast<const uint8_t*>(data.constData());

    // Skip PTS (8 bytes) — we use arrival time + jitter buffer like the Swift receiver
    const uint8_t* videoData = raw + 8;
    int videoLen = data.size() - 8;

    // Scan for SPS/PPS in AVCC-framed NALUs: [4-byte big-endian length][NALU data]
    int offset = 0;
    while (offset + 4 <= videoLen) {
        uint32_t naluLen = qFromBigEndian<uint32_t>(videoData + offset);
        if (offset + 4 + static_cast<int>(naluLen) > videoLen) break;

        uint8_t naluType = videoData[offset + 4] & 0x1F;

        if (naluType == 7) { // SPS
            m_sps = QByteArray(reinterpret_cast<const char*>(videoData + offset + 4),
                               static_cast<int>(naluLen));
        } else if (naluType == 8) { // PPS
            m_pps = QByteArray(reinterpret_cast<const char*>(videoData + offset + 4),
                               static_cast<int>(naluLen));
        }

        offset += 4 + static_cast<int>(naluLen);
    }

    // Initialize or reinitialize decoder if we have SPS/PPS
    if (!m_sps.isEmpty() && !m_pps.isEmpty()) {
        if (!m_codecCtx) {
            qDebug() << "VideoDecoder: Have SPS" << m_sps.size() << "bytes, PPS" << m_pps.size() << "bytes, initializing decoder";
            initDecoder(reinterpret_cast<const uint8_t*>(m_sps.constData()), m_sps.size(),
                        reinterpret_cast<const uint8_t*>(m_pps.constData()), m_pps.size());
        }
    }

    if (m_codecCtx) {
        decodeNalus(videoData, videoLen);
    }
}

bool VideoDecoder::initDecoder(const uint8_t* sps, int spsLen, const uint8_t* pps, int ppsLen) {
    // Build extradata in AVCC format for FFmpeg
    // Format: [1 byte version][1 byte profile][1 byte compat][1 byte level]
    //         [1 byte NALU length size - 1][1 byte num SPS | 0xE0]
    //         [2 byte SPS length][SPS data]
    //         [1 byte num PPS][2 byte PPS length][PPS data]

    if (spsLen < 4) return false;

    int extradataSize = 6 + 2 + spsLen + 1 + 2 + ppsLen;
    uint8_t* extradata = static_cast<uint8_t*>(av_malloc(extradataSize + AV_INPUT_BUFFER_PADDING_SIZE));
    if (!extradata) return false;
    memset(extradata, 0, extradataSize + AV_INPUT_BUFFER_PADDING_SIZE);

    int idx = 0;
    extradata[idx++] = 1;           // version
    extradata[idx++] = sps[1];     // profile
    extradata[idx++] = sps[2];     // compatibility
    extradata[idx++] = sps[3];     // level
    extradata[idx++] = 0xFF;       // 4 bytes NALU length size (0xFF = 3 + 1)
    extradata[idx++] = 0xE1;       // 1 SPS (0xE0 | 1)
    extradata[idx++] = static_cast<uint8_t>((spsLen >> 8) & 0xFF);
    extradata[idx++] = static_cast<uint8_t>(spsLen & 0xFF);
    memcpy(extradata + idx, sps, spsLen);
    idx += spsLen;
    extradata[idx++] = 1;          // 1 PPS
    extradata[idx++] = static_cast<uint8_t>((ppsLen >> 8) & 0xFF);
    extradata[idx++] = static_cast<uint8_t>(ppsLen & 0xFF);
    memcpy(extradata + idx, pps, ppsLen);

    const AVCodec* codec = avcodec_find_decoder(AV_CODEC_ID_H264);
    if (!codec) {
        qWarning() << "H.264 decoder not found";
        av_free(extradata);
        return false;
    }

    // If we already have a context, check for dimension change
    if (m_codecCtx) {
        // We'll destroy and recreate — dimension change detected via SPS
        destroyDecoder();
    }

    m_codecCtx = avcodec_alloc_context3(codec);
    if (!m_codecCtx) {
        av_free(extradata);
        return false;
    }

    m_codecCtx->extradata = extradata;
    m_codecCtx->extradata_size = extradataSize;

    // Low latency settings with error resilience
    m_codecCtx->flags |= AV_CODEC_FLAG_LOW_DELAY;
    m_codecCtx->flags2 |= AV_CODEC_FLAG2_FAST;
    m_codecCtx->thread_count = 2; // 2 threads for better throughput
    m_codecCtx->thread_type = FF_THREAD_SLICE;

    // Error concealment — show best-effort frames instead of artifacts
    m_codecCtx->err_recognition = 0;  // Don't reject frames with errors
    m_codecCtx->error_concealment = FF_EC_GUESS_MVS | FF_EC_DEBLOCK;

    if (avcodec_open2(m_codecCtx, codec, nullptr) < 0) {
        qWarning() << "Failed to open H.264 decoder";
        avcodec_free_context(&m_codecCtx);
        return false;
    }

    m_frame = av_frame_alloc();
    m_packet = av_packet_alloc();

    qDebug() << "H.264 decoder initialized";
    return true;
}

void VideoDecoder::destroyDecoder() {
    if (m_frame) {
        av_frame_free(&m_frame);
        m_frame = nullptr;
    }
    if (m_packet) {
        av_packet_free(&m_packet);
        m_packet = nullptr;
    }
    if (m_codecCtx) {
        avcodec_free_context(&m_codecCtx);
        m_codecCtx = nullptr;
    }
    m_currentWidth = 0;
    m_currentHeight = 0;
}

void VideoDecoder::decodeNalus(const uint8_t* data, int size) {
    // Convert AVCC framing (4-byte length prefix) to Annex-B (start codes)
    // FFmpeg's H.264 decoder can handle AVCC directly if extradata is set,
    // but we need to feed complete NALUs as a single packet.

    // Build a single packet with all NALUs
    m_packet->data = const_cast<uint8_t*>(data);
    m_packet->size = size;

    int ret = avcodec_send_packet(m_codecCtx, m_packet);
    if (ret < 0) {
        // Not necessarily an error — may happen on SPS/PPS-only packets
        if (ret != AVERROR_INVALIDDATA) return;
        // For invalid data, try to flush and recover
        avcodec_flush_buffers(m_codecCtx);
        return;
    }

    while (ret >= 0) {
        ret = avcodec_receive_frame(m_codecCtx, m_frame);
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
            break;
        }
        if (ret < 0) {
            break;
        }

        // Check for dimension change (orientation switch)
        if (m_frame->width != m_currentWidth || m_frame->height != m_currentHeight) {
            m_currentWidth = m_frame->width;
            m_currentHeight = m_frame->height;
            qDebug() << "Dimensions changed:" << m_currentWidth << "x" << m_currentHeight;
            emit dimensionsChanged(m_currentWidth, m_currentHeight);
        }

        emit frameDecoded(m_frame);
    }
}
