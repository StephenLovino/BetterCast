#pragma once

#include <QObject>
#include <QString>
#include <QList>
#include <QSet>
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

    // What this machine is announcing itself as, once startAdvertising has
    // worked it out. The name is assembled there from the user's chosen name,
    // the hostname and the platform keyword, so it is not something a caller
    // can reconstruct - and a UI claiming to show it was inventing one.
    QString advertisedName() const { return m_serviceName; }
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

    /// Join the mDNS group on every eligible interface, and forget the ones
    /// that have gone. Safe to call repeatedly; the browse timer does.
    void refreshMulticastMemberships();

    /// Send one datagram out of every eligible interface rather than letting
    /// the routing table pick one.
    void sendMulticast(const QByteArray& datagram);

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
    /// Interface names currently joined to the mDNS group, keyed the way
    /// QNetworkInterface::name() reports them.
    QSet<QString> m_joinedIfaces;

    // Browsing
    QTimer* m_browseTimer = nullptr;
    bool m_browsing = false;
    QList<DiscoveredService> m_discovered;
};
