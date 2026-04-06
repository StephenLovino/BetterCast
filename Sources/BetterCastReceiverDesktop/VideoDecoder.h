#pragma once

#include <QObject>
#include <QByteArray>
#include <QSize>

// Forward declarations for FFmpeg types
struct AVCodecContext;
struct AVFrame;
struct AVPacket;

class VideoDecoder : public QObject {
    Q_OBJECT

public:
    explicit VideoDecoder(QObject* parent = nullptr);
    ~VideoDecoder();

    void decode(const QByteArray& data);
    void reset();

signals:
    // Emitted when a frame is decoded. Receiver must copy data before returning.
    void frameDecoded(AVFrame* frame);
    void dimensionsChanged(int width, int height);
    void keyframeNeeded();  // Emitted on decode errors — receiver should request IDR from sender

private:
    bool initDecoder(const uint8_t* sps, int spsLen, const uint8_t* pps, int ppsLen);
    void destroyDecoder();
    void decodeNalus(const uint8_t* data, int size);

    AVCodecContext* m_codecCtx = nullptr;
    AVFrame* m_frame = nullptr;
    AVPacket* m_packet = nullptr;

    // Cached SPS/PPS (from current packet scan)
    QByteArray m_sps;
    QByteArray m_pps;
    // Active SPS/PPS (what the decoder was initialized with)
    QByteArray m_activeSps;
    QByteArray m_activePps;

    // Track dimensions for change detection (orientation switch)
    int m_currentWidth = 0;
    int m_currentHeight = 0;
};
