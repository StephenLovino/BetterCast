#include "NetworkSender.h"
#include <QDebug>
#include <QtEndian>

NetworkSender::NetworkSender(QObject* parent)
    : QObject(parent)
    , m_socket(new QTcpSocket(this))
{
    connect(m_socket, &QTcpSocket::connected, this, [this]() {
        qDebug() << "Sender: TCP connected to receiver";
        emit connected();
    });

    connect(m_socket, &QTcpSocket::disconnected, this, [this]() {
        qDebug() << "Sender: TCP disconnected";
        emit disconnected();
    });

    connect(m_socket, &QTcpSocket::errorOccurred, this, [this](QAbstractSocket::SocketError err) {
        Q_UNUSED(err);
        qWarning() << "Sender: TCP error:" << m_socket->errorString();
        emit error(m_socket->errorString());
    });
}

NetworkSender::~NetworkSender() {
    disconnect();
}

void NetworkSender::connectTo(const QString& host, uint16_t port) {
    if (m_socket->state() != QAbstractSocket::UnconnectedState) {
        m_socket->abort();
    }
    qDebug() << "Sender: Connecting to" << host << ":" << port;
    m_socket->connectToHost(host, port);
}

void NetworkSender::disconnect() {
    if (m_socket->state() != QAbstractSocket::UnconnectedState) {
        m_socket->abort();
    }
}

bool NetworkSender::isConnected() const {
    return m_socket->state() == QAbstractSocket::ConnectedState;
}

void NetworkSender::sendPacket(uint8_t type, const QByteArray& payload) {
    if (!isConnected()) return;

    // BetterCast TCP framing: [4B BE length][1B type][payload]
    // length = 1 (type byte) + payload size
    uint32_t totalLen = 1 + static_cast<uint32_t>(payload.size());
    uint32_t lenBE = qToBigEndian(totalLen);

    m_socket->write(reinterpret_cast<const char*>(&lenBE), 4);
    m_socket->write(reinterpret_cast<const char*>(&type), 1);
    m_socket->write(payload);
}

void NetworkSender::sendVideo(const QByteArray& payload) {
    sendPacket(0x01, payload);
}

void NetworkSender::sendAudio(const QByteArray& payload) {
    sendPacket(0x02, payload);
}
