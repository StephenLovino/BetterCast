#pragma once

#include <QObject>
#include <QString>
#include <QHash>
#include <QByteArray>

class QTcpServer;
class QTcpSocket;

/**
 * Accepts "please stream to me" invites from receivers.
 *
 * A receiver that wants to be sent a screen does not wait to be picked. It browses
 * `_bettercast-sender._tcp`, dials the port advertised there, sends one length-prefixed
 * JSON hello naming itself, and hangs up. The sender then looks that name up in its own
 * browse list and dials back to the receiver's `_bettercast._tcp` listener, which is the
 * connection that actually carries video.
 *
 * The indirection is the Mac's design; this is the Windows half of the same protocol, so
 * that phones and tablets can invite this machine exactly as they invite a Mac.
 */
class InviteListener : public QObject {
    Q_OBJECT

public:
    /// Port the Mac uses for the same service, and what receivers expect by default.
    static constexpr uint16_t DefaultPort = 51822;

    explicit InviteListener(QObject* parent = nullptr);
    ~InviteListener() override;

    /// Returns the bound port, or 0 on failure.
    uint16_t start(uint16_t port = DefaultPort);
    void stop();
    bool isListening() const;

signals:
    /// A receiver calling itself [deviceName] asked to be streamed to.
    void inviteReceived(const QString& deviceName, const QString& peerAddress);

private:
    void onNewConnection();
    void onReadyRead(QTcpSocket* socket);
    void handlePayload(const QByteArray& payload, const QString& peerAddress);

    QTcpServer* m_server = nullptr;
    /// Partial reads, per connection. An invite is tiny but TCP may still split it.
    QHash<QTcpSocket*, QByteArray> m_buffers;
};
