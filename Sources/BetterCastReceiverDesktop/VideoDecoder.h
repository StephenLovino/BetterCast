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

signals:
    // Emitted when a frame is decoded. Receiver must copy data before returning.
    void frameDecoded(AVFrame* frame);
    void dimensionsChanged(int width, int height);

private:
    bool initDecoder(const uint8_t* sps, int spsLen, const uint8_t* pps, int ppsLen);
    void destroyDecoder();
    void decodeNalus(const uint8_t* data, int size);

    AVCodecContext* m_codecCtx = nullptr;
    AVFrame* m_frame = nullptr;
    AVPacket* m_packet = nullptr;

    // Cached SPS/PPS
    QByteArray m_sps;
    QByteArray m_pps;

    // Track dimensions for change detection (orientation switch)
    int m_currentWidth = 0;
    int m_currentHeight = 0;
};
