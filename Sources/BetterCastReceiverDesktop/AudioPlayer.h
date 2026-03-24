#pragma once

#include <QObject>
#include <QByteArray>
#include <QAudioSink>
#include <QAudioFormat>
#include <QIODevice>
#include <QMutex>
#include <QBuffer>

class AudioPlayer : public QObject {
    Q_OBJECT

public:
    explicit AudioPlayer(QObject* parent = nullptr);
    ~AudioPlayer();

public slots:
    void onPcmDecoded(const QByteArray& pcmData, int sampleRate, int channels);

private:
    void ensureSink(int sampleRate, int channels);

    QAudioSink* m_sink = nullptr;
    QIODevice* m_ioDevice = nullptr;
    int m_sampleRate = 0;
    int m_channels = 0;
};
