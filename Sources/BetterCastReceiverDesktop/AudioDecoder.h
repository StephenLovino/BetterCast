#pragma once

#include <QObject>
#include <QByteArray>

struct AVCodecContext;
struct AVFrame;
struct AVPacket;

class AudioDecoder : public QObject {
    Q_OBJECT

public:
    explicit AudioDecoder(QObject* parent = nullptr);
    ~AudioDecoder();

    void decode(const QByteArray& aacData);

signals:
    // Emitted with decoded PCM: interleaved float32, sampleRate, channels
    void pcmDecoded(const QByteArray& pcmData, int sampleRate, int channels);

private:
    bool initDecoder();
    void destroyDecoder();

    AVCodecContext* m_codecCtx = nullptr;
    AVFrame* m_frame = nullptr;
    AVPacket* m_packet = nullptr;
    bool m_initialized = false;
};
