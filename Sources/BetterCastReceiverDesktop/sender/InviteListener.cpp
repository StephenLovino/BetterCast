#include "InviteListener.h"
#include "../MainWindow.h"  // for LogManager

#include <QTcpServer>
#include <QTcpSocket>
#include <QHostAddress>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonParseError>
#include <QtEndian>

namespace {
/// Matches `InputEventType.command` on the Mac.
constexpr int kTypeCommand = 99;
/// Device-hello command the sender listens for on the invite connection.
constexpr int kCommandDeviceHello = 770;
/// An invite is a couple of hundred bytes; anything larger is not one of ours.
constexpr int kMaxPayload = 8 * 1024;
}

InviteListener::InviteListener(QObject* parent)
    : QObject(parent)
    , m_server(new QTcpServer(this))
{
    connect(m_server, &QTcpServer::newConnection, this, &InviteListener::onNewConnection);
}

InviteListener::~InviteListener() {
    stop();
}

uint16_t InviteListener::start(uint16_t port) {
    if (m_server->isListening()) return static_cast<uint16_t>(m_server->serverPort());

    if (!m_server->listen(QHostAddress::Any, port)) {
        LogManager::instance().log(
            QString("Invite listener: could not bind port %1 (%2)")
                .arg(port).arg(m_server->errorString()));
        return 0;
    }

    LogManager::instance().log(
        QString("Invite listener: waiting for receiver invites on port %1").arg(port));
    return static_cast<uint16_t>(m_server->serverPort());
}

void InviteListener::stop() {
    for (auto it = m_buffers.begin(); it != m_buffers.end(); ++it) {
        it.key()->deleteLater();
    }
    m_buffers.clear();
    if (m_server->isListening()) m_server->close();
}

bool InviteListener::isListening() const {
    return m_server->isListening();
}

void InviteListener::onNewConnection() {
    while (m_server->hasPendingConnections()) {
        QTcpSocket* socket = m_server->nextPendingConnection();
        if (!socket) continue;

        m_buffers.insert(socket, QByteArray());

        connect(socket, &QTcpSocket::readyRead, this, [this, socket]() {
            onReadyRead(socket);
        });
        connect(socket, &QTcpSocket::disconnected, this, [this, socket]() {
            m_buffers.remove(socket);
            socket->deleteLater();
        });
    }
}

void InviteListener::onReadyRead(QTcpSocket* socket) {
    auto it = m_buffers.find(socket);
    if (it == m_buffers.end()) return;

    it.value().append(socket->readAll());
    QByteArray& buf = it.value();

    // [4B big-endian length][JSON]. The phone hangs up straight after writing, so all
    // we ever need is the first frame.
    while (buf.size() >= 4) {
        uint32_t len = qFromBigEndian<uint32_t>(
            reinterpret_cast<const uchar*>(buf.constData()));
        if (len == 0 || len > kMaxPayload) {
            LogManager::instance().log(
                QString("Invite listener: bogus frame length %1, dropping connection").arg(len));
            socket->abort();
            return;
        }
        if (static_cast<uint32_t>(buf.size()) < 4 + len) return;  // wait for the rest

        QByteArray payload = buf.mid(4, static_cast<int>(len));
        buf.remove(0, static_cast<int>(4 + len));
        handlePayload(payload, socket->peerAddress().toString());
    }
}

void InviteListener::handlePayload(const QByteArray& payload, const QString& peerAddress) {
    QJsonParseError err{};
    QJsonDocument doc = QJsonDocument::fromJson(payload, &err);
    if (err.error != QJsonParseError::NoError || !doc.isObject()) {
        LogManager::instance().log(
            QString("Invite listener: could not parse invite from %1 (%2)")
                .arg(peerAddress, err.errorString()));
        return;
    }

    QJsonObject obj = doc.object();
    const int type = obj.value("type").toInt(-1);
    const int keyCode = obj.value("keyCode").toInt(-1);
    if (type != kTypeCommand || keyCode != kCommandDeviceHello) {
        // Heartbeats and keyframe requests belong on the streaming connection, not here.
        return;
    }

    const QString deviceName = obj.value("deviceName").toString();
    if (deviceName.isEmpty()) {
        LogManager::instance().log(
            QString("Invite listener: hello from %1 carried no device name").arg(peerAddress));
        return;
    }

    LogManager::instance().log(
        QString("Invite listener: '%1' (%2) asked to be streamed to")
            .arg(deviceName, peerAddress));
    emit inviteReceived(deviceName, peerAddress);
}
