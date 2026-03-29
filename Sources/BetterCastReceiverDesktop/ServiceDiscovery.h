#pragma once

#include <QObject>
#include <QString>
#include <QList>
#include <QUdpSocket>
#include <QTimer>
#include <QHostAddress>

struct DiscoveredService {
    QString name;
    QString host;
    uint16_t port = 0;
};

class ServiceDiscovery : public QObject {
    Q_OBJECT

public:
    explicit ServiceDiscovery(QObject* parent = nullptr);
    ~ServiceDiscovery();

    // Start advertising as a BetterCast receiver
    void startAdvertising(uint16_t tcpPort);
    void stopAdvertising();

    // Browse for BetterCast senders (not needed — sender browses for us)
    void startBrowsing();
    void stopBrowsing();

signals:
    void serviceFound(const DiscoveredService& service);
    void serviceLost(const QString& name);

private slots:
    void onMdnsReadyRead();
    void sendAnnouncement();

private:
    void handleMdnsQuery(const QByteArray& packet, const QHostAddress& sender, uint16_t senderPort);
    QByteArray buildMdnsResponse(uint16_t transactionId, const QHostAddress& targetAddr);
    QByteArray encodeDnsName(const QString& name);
    QString getHostname();
    QList<QHostAddress> getLocalAddresses();

#ifdef HAS_MDNS
    void* m_registerRef = nullptr;
    void* m_browseRef = nullptr;
#endif

    // Embedded mDNS responder
    QUdpSocket* m_mdnsSocket = nullptr;
    QTimer* m_announceTimer = nullptr;
    uint16_t m_advertisedPort = 0;
    QString m_serviceName;
    bool m_advertising = false;
    int m_announceCount = 0;
};
