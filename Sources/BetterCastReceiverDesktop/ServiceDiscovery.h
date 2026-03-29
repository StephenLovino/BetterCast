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

    bool operator==(const DiscoveredService& o) const {
        return name == o.name && host == o.host && port == o.port;
    }
};

class ServiceDiscovery : public QObject {
    Q_OBJECT

public:
    explicit ServiceDiscovery(QObject* parent = nullptr);
    ~ServiceDiscovery();

    // Start advertising as a BetterCast receiver
    void startAdvertising(uint16_t tcpPort);
    void stopAdvertising();

    // Browse for other BetterCast receivers on the network
    void startBrowsing();
    void stopBrowsing();

    const QList<DiscoveredService>& discoveredServices() const { return m_discovered; }

signals:
    void serviceFound(const DiscoveredService& service);
    void serviceLost(const QString& name);

private slots:
    void onMdnsReadyRead();
    void sendAnnouncement();
    void sendBrowseQuery();

private:
    void handleMdnsQuery(const QByteArray& packet, const QHostAddress& sender, uint16_t senderPort);
    void handleMdnsResponse(const QByteArray& packet);
    QByteArray buildMdnsResponse(uint16_t transactionId, const QHostAddress& targetAddr);
    QByteArray buildBrowseQuery();
    QByteArray encodeDnsName(const QString& name);
    QString decodeDnsName(const QByteArray& packet, int& offset);
    QString getHostname();
    QList<QHostAddress> getLocalAddresses();
    bool isOwnAddress(const QHostAddress& addr);
    void ensureMdnsSocket();

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

    // Browsing
    QTimer* m_browseTimer = nullptr;
    bool m_browsing = false;
    QList<DiscoveredService> m_discovered;
};
