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

class NetworkListener : public QObject {
    Q_OBJECT

public:
    explicit NetworkListener(QObject* parent = nullptr);
    ~NetworkListener();

    void setup(VideoDecoder* decoder, VideoRenderer* renderer);
    void start();
    void connectTo(const QString& host, uint16_t port);

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
    void handleVideoData(const QByteArray& data);
    void handleUdpPacket(const QByteArray& data);

    // TCP
    QTcpServer* m_tcpServer = nullptr;
    QList<QTcpSocket*> m_clients;
    QHash<QTcpSocket*, QByteArray> m_tcpBuffers;

    // UDP
    QUdpSocket* m_udpSocket = nullptr;
    static constexpr uint16_t kDefaultTcpPort = 51820;
    static constexpr uint16_t kDefaultUdpPort = 51821;

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

    // Stats
    int m_udpPacketsReceived = 0;
    int m_udpFramesReassembled = 0;
    QDateTime m_lastStatsTime;
};
