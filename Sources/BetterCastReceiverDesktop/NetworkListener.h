#pragma once

#include <QObject>
#include <QTcpServer>
#include <QTcpSocket>
#include <QUdpSocket>
#include <QTimer>
#include <QMutex>
#include <QHash>
#include <QByteArray>
#include <QDateTime>

#include "InputEvent.h"

class VideoDecoder;
class VideoRenderer;
class AudioDecoder;

class NetworkListener : public QObject {
    Q_OBJECT

public:
    explicit NetworkListener(QObject* parent = nullptr);
    ~NetworkListener();

    void setup(VideoDecoder* decoder, VideoRenderer* renderer, AudioDecoder* audioDecoder = nullptr);
    void start();
    void connectTo(const QString& host, uint16_t port);
    void disconnectAll();
    const QList<QTcpSocket*>& clients() const { return m_clients; }
    uint16_t actualTcpPort() const;

signals:
    void connectionEstablished();
    void connectionLost();
    void statusChanged(const QString& status);

public slots:
    void sendInputEvent(const InputEvent& event);

private slots:
    void onNewTcpConnection();
    void onTcpReadyRead();
    void onTcpDisconnected();
    void onUdpReadyRead();
    void onHeartbeatTick();

private:
    void processTcpBuffer(QTcpSocket* socket);
    void handleVideoData(const QByteArray& data, bool hasPtsPrefix = true);
    void handleAudioData(const QByteArray& data);
    void handleUdpPacket(const QByteArray& data);

    // TCP
    QTcpServer* m_tcpServer = nullptr;
    QList<QTcpSocket*> m_clients;
    QHash<QTcpSocket*, QByteArray> m_tcpBuffers;

    // Per-connection format detection: true = type-byte framing, false = legacy
    // -1 = not yet detected
    QHash<QTcpSocket*, int> m_connectionFormat;

    // UDP
    QUdpSocket* m_udpSocket = nullptr;
    static constexpr uint16_t kDefaultTcpPort = 51820;
    static constexpr uint16_t kDefaultUdpPort = 51821;
    static constexpr uint32_t kMaxPacketSize = 8 * 1024 * 1024;   // 8MB per frame max
    static constexpr int kMaxBufferSize = 32 * 1024 * 1024;       // 32MB buffer limit

    // UDP reassembly
    struct UdpFrameEntry {
        int totalChunks = 0;
        QHash<uint16_t, QByteArray> chunks;
        QDateTime timestamp;
    };
    QHash<uint32_t, UdpFrameEntry> m_udpBuffer;
    QMutex m_udpMutex;
    uint32_t m_lastDecodedFrameId = 0;
    QDateTime m_lastKeyframeRequest;

    // Heartbeat
    QTimer* m_heartbeatTimer = nullptr;

    // Dependencies
    VideoDecoder* m_decoder = nullptr;
    VideoRenderer* m_renderer = nullptr;
    AudioDecoder* m_audioDecoder = nullptr;

    // Stats
    int m_udpPacketsReceived = 0;
    int m_udpFramesReassembled = 0;
    QDateTime m_lastStatsTime;
};
