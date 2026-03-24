#include "AudioPlayer.h"
#include <QDebug>
#include <QMediaDevices>
#include <QAudioDevice>

AudioPlayer::AudioPlayer(QObject* parent)
    : QObject(parent)
{
}

AudioPlayer::~AudioPlayer() {
    if (m_sink) {
        m_sink->stop();
        delete m_sink;
    }
}

void AudioPlayer::ensureSink(int sampleRate, int channels) {
    if (m_sink && m_sampleRate == sampleRate && m_channels == channels) {
        return; // Already configured
    }

    // Tear down old sink
    if (m_sink) {
        m_sink->stop();
        delete m_sink;
        m_sink = nullptr;
        m_ioDevice = nullptr;
    }

    QAudioFormat format;
    format.setSampleRate(sampleRate);
    format.setChannelCount(channels);
    format.setSampleFormat(QAudioFormat::Float); // We send float32 PCM

    QAudioDevice device = QMediaDevices::defaultAudioOutput();
    if (!device.isFormatSupported(format)) {
        qWarning() << "AudioPlayer: Format not supported by device, trying anyway";
    }

    m_sink = new QAudioSink(device, format, this);
    m_sink->setBufferSize(sampleRate * channels * sizeof(float) / 5); // ~200ms buffer
    m_ioDevice = m_sink->start();

    m_sampleRate = sampleRate;
    m_channels = channels;

    qDebug() << "AudioPlayer: Started" << sampleRate << "Hz" << channels << "ch float32";
}

void AudioPlayer::onPcmDecoded(const QByteArray& pcmData, int sampleRate, int channels) {
    ensureSink(sampleRate, channels);

    if (m_ioDevice) {
        m_ioDevice->write(pcmData);
    }
}
