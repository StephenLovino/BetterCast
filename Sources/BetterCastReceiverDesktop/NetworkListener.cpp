#include "NetworkListener.h"
#include "VideoDecoder.h"
#include "VideoRenderer.h"
#include "AudioDecoder.h"

#include <QHostAddress>
#include <QtEndian>
#include <QDebug>

NetworkListener::NetworkListener(QObject* parent)
    : QObject(parent)
    , m_lastKeyframeRequest(QDateTime::fromMSecsSinceEpoch(0))
    , m_lastStatsTime(QDateTime::currentDateTime())
{
}

NetworkListener::~NetworkListener() {
    for (auto* client : m_clients) {
        client->disconnectFromHost();
    }
}

void NetworkListener::setup(VideoDecoder* decoder, VideoRenderer* renderer, AudioDecoder* audioDecoder) {
    m_decoder = decoder;
    m_renderer = renderer;
    m_audioDecoder = audioDecoder;
}

void NetworkListener::start() {
    // Start TCP server
    m_tcpServer = new QTcpServer(this);
    connect(m_tcpServer, &QTcpServer::newConnection, this, &NetworkListener::onNewTcpConnection);

    if (m_tcpServer->listen(QHostAddress::Any, kDefaultTcpPort)) {
        qDebug() << "TCP listening on port" << m_tcpServer->serverPort();
        emit statusChanged(QString("Listening on port %1").arg(m_tcpServer->serverPort()));
    } else {
        // Try any available port if default is taken
        if (m_tcpServer->listen(QHostAddress::Any, 0)) {
            qDebug() << "TCP listening on port" << m_tcpServer->serverPort();
            emit statusChanged(QString("Listening on port %1").arg(m_tcpServer->serverPort()));
        } else {
            qWarning() << "TCP listen failed:" << m_tcpServer->errorString();
            emit statusChanged("TCP listen failed: " + m_tcpServer->errorString());
        }
    }

    // Start UDP socket
    m_udpSocket = new QUdpSocket(this);
    if (m_udpSocket->bind(QHostAddress::Any, kDefaultUdpPort)) {
        connect(m_udpSocket, &QUdpSocket::readyRead, this, &NetworkListener::onUdpReadyRead);
        qDebug() << "UDP listening on port" << kDefaultUdpPort;
    } else {
        qWarning() << "UDP bind failed:" << m_udpSocket->errorString();
    }

    // Heartbeat timer (every 500ms, matching Swift receiver)
    m_heartbeatTimer = new QTimer(this);
    connect(m_heartbeatTimer, &QTimer::timeout, this, &NetworkListener::onHeartbeatTick);
    m_heartbeatTimer->start(500);
}

void NetworkListener::connectTo(const QString& host, uint16_t port) {
    auto* socket = new QTcpSocket(this);
    socket->setSocketOption(QAbstractSocket::LowDelayOption, 1);
    socket->setSocketOption(QAbstractSocket::KeepAliveOption, 1);

    connect(socket, &QTcpSocket::connected, this, [this, socket]() {
        qDebug() << "Connected to sender:" << socket->peerAddress().toString() << socket->peerPort();
        m_clients.append(socket);
        m_tcpBuffers[socket] = QByteArray();
        emit connectionEstablished();
        emit statusChanged("Connected to " + socket->peerAddress().toString());
    });

    connect(socket, &QTcpSocket::readyRead, this, &NetworkListener::onTcpReadyRead);
    connect(socket, &QTcpSocket::disconnected, this, &NetworkListener::onTcpDisconnected);

    emit statusChanged(QString("Connecting to %1:%2...").arg(host).arg(port));
    socket->connectToHost(host, port);
}

void NetworkListener::onNewTcpConnection() {
    while (m_tcpServer->hasPendingConnections()) {
        auto* socket = m_tcpServer->nextPendingConnection();
        socket->setSocketOption(QAbstractSocket::LowDelayOption, 1);
        socket->setSocketOption(QAbstractSocket::KeepAliveOption, 1);

        qDebug() << "New TCP connection from" << socket->peerAddress().toString();
        m_clients.append(socket);
        m_tcpBuffers[socket] = QByteArray();

        connect(socket, &QTcpSocket::readyRead, this, &NetworkListener::onTcpReadyRead);
        connect(socket, &QTcpSocket::disconnected, this, &NetworkListener::onTcpDisconnected);

        emit connectionEstablished();
        emit statusChanged("Connected from " + socket->peerAddress().toString());
    }
}

void NetworkListener::onTcpReadyRead() {
    auto* socket = qobject_cast<QTcpSocket*>(sender());
    if (!socket) return;

    m_tcpBuffers[socket].append(socket->readAll());
    processTcpBuffer(socket);
}

void NetworkListener::processTcpBuffer(QTcpSocket* socket) {
    QByteArray& buffer = m_tcpBuffers[socket];

    // Length-prefixed framing: [uint32_be length][body]
    while (buffer.size() >= 4) {
        uint32_t length = qFromBigEndian<uint32_t>(
            reinterpret_cast<const uchar*>(buffer.constData()));

        int totalNeeded = 4 + static_cast<int>(length);
        if (buffer.size() < totalNeeded) {
            break; // Wait for more data
        }

        QByteArray body = buffer.mid(4, static_cast<int>(length));
        buffer.remove(0, totalNeeded);

        // Check for packet type byte (new framing: first byte is type)
        if (body.size() > 1) {
            uint8_t typeByte = static_cast<uint8_t>(body[0]);
            if (typeByte == 0x01) {
                // Video packet — strip type byte
                handleVideoData(body.mid(1));
                continue;
            } else if (typeByte == 0x02) {
                // Audio packet — strip type byte
                handleAudioData(body.mid(1));
                continue;
            }
        }
        // Legacy: no type byte, treat as video (backward compat)
        handleVideoData(body);
    }
}

void NetworkListener::handleVideoData(const QByteArray& data) {
    static int frameCount = 0;
    frameCount++;
    if (frameCount <= 3 || frameCount % 100 == 0) {
        qDebug() << "NetworkListener: Received video data" << data.size() << "bytes (frame" << frameCount << ")";
    }
    if (m_decoder) {
        m_decoder->decode(data);
    }
}

void NetworkListener::handleAudioData(const QByteArray& data) {
    static int audioCount = 0;
    audioCount++;
    if (audioCount <= 3 || audioCount % 200 == 0) {
        qDebug() << "NetworkListener: Received audio data" << data.size() << "bytes (packet" << audioCount << ")";
    }
    if (m_audioDecoder) {
        m_audioDecoder->decode(data);
    }
}

void NetworkListener::onTcpDisconnected() {
    auto* socket = qobject_cast<QTcpSocket*>(sender());
    if (!socket) return;

    qDebug() << "TCP client disconnected:" << socket->peerAddress().toString();
    m_clients.removeAll(socket);
    m_tcpBuffers.remove(socket);
    socket->deleteLater();

    if (m_clients.isEmpty()) {
        emit connectionLost();
        emit statusChanged("Waiting for connection...");
    }
}

void NetworkListener::onUdpReadyRead() {
    while (m_udpSocket->hasPendingDatagrams()) {
        QByteArray datagram;
        datagram.resize(static_cast<int>(m_udpSocket->pendingDatagramSize()));
        m_udpSocket->readDatagram(datagram.data(), datagram.size());

        if (!datagram.isEmpty()) {
            handleUdpPacket(datagram);
        }
    }
}

void NetworkListener::handleUdpPacket(const QByteArray& data) {
    if (data.size() <= 8) return;

    const uchar* raw = reinterpret_cast<const uchar*>(data.constData());
    uint32_t frameId = qFromBigEndian<uint32_t>(raw);
    uint16_t chunkId = qFromBigEndian<uint16_t>(raw + 4);
    uint16_t totalChunks = qFromBigEndian<uint16_t>(raw + 6);

    QByteArray payload = data.mid(8);

    QMutexLocker lock(&m_udpMutex);

    if (m_lastDecodedFrameId == 0) {
        m_lastDecodedFrameId = frameId - 1;
    }

    m_udpPacketsReceived++;

    // Stats logging every 3 seconds
    auto now = QDateTime::currentDateTime();
    if (m_lastStatsTime.msecsTo(now) > 3000) {
        qDebug() << "UDP Stats (3s): Pkts:" << m_udpPacketsReceived
                 << "Frames:" << m_udpFramesReassembled;
        m_udpPacketsReceived = 0;
        m_udpFramesReassembled = 0;
        m_lastStatsTime = now;
    }

    if (!m_udpBuffer.contains(frameId)) {
        UdpFrameEntry entry;
        entry.totalChunks = totalChunks;
        entry.timestamp = now;
        m_udpBuffer[frameId] = entry;
    }

    m_udpBuffer[frameId].chunks[chunkId] = payload;

    if (m_udpBuffer[frameId].chunks.size() == m_udpBuffer[frameId].totalChunks) {
        m_udpFramesReassembled++;

        // Gap detection — request IDR if frames were skipped
        int diff = static_cast<int>(frameId) - static_cast<int>(m_lastDecodedFrameId);
        if (diff > 1 && diff < 1000) {
            if (m_lastKeyframeRequest.msecsTo(now) > 2000) {
                qDebug() << "Frame gap detected" << m_lastDecodedFrameId << "->" << frameId << "requesting IDR";
                sendInputEvent(InputEvent(InputEventType::Command, 0, 0, kIDRRequestKeyCode));
                m_lastKeyframeRequest = now;
            }
        }
        m_lastDecodedFrameId = frameId;

        // Reassemble in chunk order
        auto& entry = m_udpBuffer[frameId];
        QList<uint16_t> keys = entry.chunks.keys();
        std::sort(keys.begin(), keys.end());

        QByteArray fullData;
        for (uint16_t k : keys) {
            fullData.append(entry.chunks[k]);
        }

        m_udpBuffer.remove(frameId);

        // Unlock before decode (decode may be slow)
        lock.unlock();
        handleVideoData(fullData);
        return;
    }

    // Periodic cleanup of stale incomplete frames
    if (m_udpPacketsReceived % 100 == 0) {
        QList<uint32_t> staleKeys;
        for (auto it = m_udpBuffer.begin(); it != m_udpBuffer.end(); ++it) {
            if (it->timestamp.msecsTo(now) > 1000) {
                staleKeys.append(it.key());
            }
        }
        for (uint32_t key : staleKeys) {
            m_udpBuffer.remove(key);
        }
    }
}

void NetworkListener::onHeartbeatTick() {
    InputEvent heartbeat(InputEventType::Command, 0, 0, kHeartbeatKeyCode);
    QByteArray packet = heartbeat.toPacket();

    for (auto* client : m_clients) {
        client->write(packet);
    }
}

void NetworkListener::sendInputEvent(const InputEvent& event) {
    bool isCritical = (event.type == InputEventType::LeftMouseDown ||
                       event.type == InputEventType::LeftMouseUp ||
                       event.type == InputEventType::RightMouseDown ||
                       event.type == InputEventType::RightMouseUp ||
                       event.type == InputEventType::KeyDown ||
                       event.type == InputEventType::KeyUp ||
                       event.type == InputEventType::Command);

    int repeatCount = isCritical ? 3 : 1;
    QByteArray packet = event.toPacket();

    for (auto* client : m_clients) {
        for (int i = 0; i < repeatCount; i++) {
            client->write(packet);
        }
    }
}
