#include "NetworkListener.h"
#include "LogManager.h"
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

uint16_t NetworkListener::actualTcpPort() const {
    if (m_tcpServer && m_tcpServer->isListening())
        return m_tcpServer->serverPort();
    return kDefaultTcpPort;
}

void NetworkListener::start() {
    // Start TCP server
    m_tcpServer = new QTcpServer(this);
    connect(m_tcpServer, &QTcpServer::newConnection, this, &NetworkListener::onNewTcpConnection);

    if (m_tcpServer->listen(QHostAddress::Any, kDefaultTcpPort)) {
        LogManager::instance().log(QString("TCP listening on port %1").arg(m_tcpServer->serverPort()));
        emit statusChanged(QString("Listening on port %1").arg(m_tcpServer->serverPort()));
    } else {
        LogManager::instance().log(QString("TCP port %1 unavailable: %2 — trying system-assigned port")
                                       .arg(kDefaultTcpPort).arg(m_tcpServer->errorString()));
        // Try any available port if default is taken
        if (m_tcpServer->listen(QHostAddress::Any, 0)) {
            LogManager::instance().log(QString("TCP listening on fallback port %1").arg(m_tcpServer->serverPort()));
            emit statusChanged(QString("Listening on port %1 (fallback)").arg(m_tcpServer->serverPort()));
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

void NetworkListener::disconnectAll() {
    for (auto* client : m_clients) {
        client->disconnect(); // disconnect signals
        client->abort();
        client->deleteLater();
    }
    m_clients.clear();
    m_tcpBuffers.clear();
    m_connectionFormat.clear();
    // Reset decoder so next connection starts fresh
    if (m_decoder) {
        m_decoder->reset();
    }
}

void NetworkListener::connectTo(const QString& host, uint16_t port) {
    // Disconnect any existing outgoing connections to avoid duplicates
    disconnectAll();

    auto* socket = new QTcpSocket(this);
    socket->setSocketOption(QAbstractSocket::LowDelayOption, 1);
    socket->setSocketOption(QAbstractSocket::KeepAliveOption, 1);

    // A dial that fails used to fail silently: no error handler, no timeout,
    // and the socket left behind. Typing a wrong phone address, or dialling a
    // phone that is not sharing, looked exactly like waiting. Now both a
    // refusal and a no-answer are logged, reported, and cleaned up - once.
    constexpr int kConnectTimeoutMs = 8000;
    auto* timeout = new QTimer(socket);
    timeout->setSingleShot(true);
    auto fail = [this, socket, host, port, timeout](const QString& reason) {
        if (socket->property("bcDialFailed").toBool() || m_clients.contains(socket)) return;
        socket->setProperty("bcDialFailed", true);
        timeout->stop();
        LogManager::instance().log(
            QString("Could not connect to %1:%2 — %3").arg(host).arg(port).arg(reason));
        emit statusChanged(QString("Could not connect to %1:%2").arg(host).arg(port));
        emit connectFailed(host, reason);
        socket->abort();
        socket->deleteLater();
    };
    connect(timeout, &QTimer::timeout, this, [fail]() {
        fail(QStringLiteral("no answer within 8 seconds"));
    });
    connect(socket, &QAbstractSocket::errorOccurred, this,
            [socket, fail](QAbstractSocket::SocketError) { fail(socket->errorString()); });
    timeout->start(kConnectTimeoutMs);

    connect(socket, &QTcpSocket::connected, this, [this, socket, timeout]() {
        timeout->stop();
        LogManager::instance().log("Connected to " + socket->peerAddress().toString());
        m_clients.append(socket);
        m_tcpBuffers[socket] = QByteArray();
        m_connectionFormat[socket] = -1; // auto-detect on first frame
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
        m_connectionFormat[socket] = -1; // auto-detect on first frame

        connect(socket, &QTcpSocket::readyRead, this, &NetworkListener::onTcpReadyRead);
        connect(socket, &QTcpSocket::disconnected, this, &NetworkListener::onTcpDisconnected);

        emit connectionEstablished();
        emit statusChanged("Connected from " + socket->peerAddress().toString());
    }
}

void NetworkListener::onTcpReadyRead() {
    auto* socket = qobject_cast<QTcpSocket*>(sender());
    if (!socket) return;

    QByteArray& buffer = m_tcpBuffers[socket];
    buffer.append(socket->readAll());

    // Safety: if buffer grows beyond 32MB, framing is likely desynced — reset
    if (buffer.size() > kMaxBufferSize) {
        // Through LogManager, not qWarning. Both desync paths used to report
        // only to the debug output, which no shipped build shows — so a stream
        // that lost alignment produced a log full of impossible NALU sizes and
        // no line saying why.
        LogManager::instance().log(
            QString("TCP: buffer passed %1 MB — framing has desynced, resetting. "
                    "Everything decoded after this point is misaligned.")
                .arg(kMaxBufferSize / (1024 * 1024)));
        buffer.clear();
        return;
    }

    processTcpBuffer(socket);
}

void NetworkListener::processTcpBuffer(QTcpSocket* socket) {
    QByteArray& buffer = m_tcpBuffers[socket];
    int consumed = 0;

    // Length-prefixed framing: [uint32_be length][body]
    while (buffer.size() - consumed >= 4) {
        uint32_t length = qFromBigEndian<uint32_t>(
            reinterpret_cast<const uchar*>(buffer.constData() + consumed));

        // Sanity check: single frame should never exceed 8MB
        if (length > kMaxPacketSize) {
            // This is the moment a stream goes wrong, and it was invisible.
            // Clearing the buffer does not resynchronise anything: the next
            // bytes are still mid-frame, so this fires again and again while
            // the decoder is handed nonsense. Saying so once, loudly, beats
            // reading it off impossible NALU lengths afterwards.
            QString head;
            for (int i = 0; i < qMin(16, buffer.size() - consumed); i++) {
                head += QString("%1 ").arg(
                    static_cast<uint8_t>(buffer[consumed + i]), 2, 16, QChar('0'));
            }
            LogManager::instance().log(
                QString("TCP: framing lost — claimed packet length %1 exceeds the %2 byte "
                        "maximum, so the stream is misaligned from here [%3]")
                    .arg(length).arg(kMaxPacketSize).arg(head.trimmed()));
            buffer.clear();
            consumed = 0;
            return;
        }

        int totalNeeded = 4 + static_cast<int>(length);
        if (buffer.size() - consumed < totalNeeded) {
            break; // Wait for more data
        }

        QByteArray body = buffer.mid(consumed + 4, static_cast<int>(length));
        consumed += totalNeeded;

        // Auto-detect framing format on first frame per connection.
        // Type-byte format (Mac sender): [0x01=video|0x02=audio][payload]
        // Legacy format (Android/Swift): [8-byte PTS][NALUs] — first frame PTS=0 so byte[0]=0x00
        int& format = m_connectionFormat[socket];
        if (format < 0 && body.size() > 1) {
            uint8_t firstByte = static_cast<uint8_t>(body[0]);
            if (firstByte == 0x01 || firstByte == 0x02) {
                format = 1; // type-byte framing
                LogManager::instance().log("Detected type-byte framing (desktop sender)");
            } else {
                format = 0; // legacy framing
                LogManager::instance().log("Detected legacy framing (Android/Swift sender)");
            }
        }

        if (format == 1 && body.size() > 1) {
            uint8_t typeByte = static_cast<uint8_t>(body[0]);
            if (typeByte == 0x01) {
                // The type byte is *in addition to* the PTS header, not instead of it:
                // the Mac sends [0x01][8-byte PTS][AVCC NALUs]. Passing false here made
                // the decoder read the first four bytes of a little-endian nanosecond
                // timestamp as a big-endian NALU length — a near-random 32-bit value that
                // crashed the app one frame into every Mac-to-Windows stream.
                handleVideoData(body.mid(1), true);
            } else if (typeByte == 0x02) {
                handleAudioData(body.mid(1));
            }
            // else: unknown type, skip
        } else {
            // Legacy: has 8-byte PTS prefix
            handleVideoData(body, true);
        }
    }

    // Remove all consumed bytes at once (avoids repeated O(n) shifts)
    if (consumed > 0) {
        buffer.remove(0, consumed);
    }
}

void NetworkListener::handleVideoData(const QByteArray& data, bool hasPtsPrefix) {
    static int frameCount = 0;
    frameCount++;
    if (frameCount <= 5 || frameCount % 300 == 0) {
        // Log first few bytes for debugging framing issues
        QString hexPreview;
        int previewLen = qMin(data.size(), 16);
        for (int i = 0; i < previewLen; i++) {
            hexPreview += QString("%1 ").arg(static_cast<uint8_t>(data[i]), 2, 16, QChar('0'));
        }
        LogManager::instance().log(QString("Video: frame %1, %2 bytes, pts=%3 [%4]")
                                   .arg(frameCount).arg(data.size()).arg(hasPtsPrefix).arg(hexPreview.trimmed()));
    }
    if (m_decoder) {
        m_decoder->decode(data, hasPtsPrefix);
    }
}

void NetworkListener::handleAudioData(const QByteArray& data) {
    static int audioCount = 0;
    audioCount++;
    if (audioCount <= 3 || audioCount % 200 == 0) {
        // Also in the log rather than only the debug output: whether audio is
        // arriving at all is the first question when a stream that used to
        // work stops working, and it could not be answered from a log file.
        LogManager::instance().log(
            QString("Audio: packet %1, %2 bytes, decoder %3")
                .arg(audioCount).arg(data.size())
                .arg(m_audioDecoder ? "attached" : "none"));
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
    m_connectionFormat.remove(socket);
    socket->deleteLater();

    if (m_clients.isEmpty()) {
        // Reset decoder so next connection starts fresh
        if (m_decoder) {
            m_decoder->reset();
        }
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
