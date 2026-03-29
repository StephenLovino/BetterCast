#pragma once

#include <QObject>
#include <QTcpSocket>
#include <QByteArray>
#include <cstdint>

// TCP client that sends video/audio data using BetterCast wire protocol.
// Format: [4B BE length][1B type (0x01=video, 0x02=audio)][payload]
class NetworkSender : public QObject {
    Q_OBJECT
public:
    explicit NetworkSender(QObject* parent = nullptr);
    ~NetworkSender() override;

    void connectTo(const QString& host, uint16_t port);
    void disconnect();
    bool isConnected() const;

    void sendVideo(const QByteArray& payload);
    void sendAudio(const QByteArray& payload);

signals:
    void connected();
    void disconnected();
    void error(const QString& message);

private:
    void sendPacket(uint8_t type, const QByteArray& payload);

    QTcpSocket* m_socket = nullptr;
};
