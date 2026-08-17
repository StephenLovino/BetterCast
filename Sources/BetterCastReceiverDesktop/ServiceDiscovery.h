#pragma once

#include <QObject>
#include <QString>
#include <QList>
#include <QHash>
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

    /**
     * Also advertise this machine as a *sender*, on `_bettercast-sender._tcp`.
     *
     * Receivers browse that type to build their "pick a sender" list and then dial the
     * advertised port to invite the sender to stream to them. Only the Mac advertised
     * it before, which is why the Windows machine never appeared on the phone or iPad
     * even though it was plainly on the network as a receiver.
     */
    void advertiseSenderService(uint16_t invitePort);
    void stopAdvertisingSenderService();

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
    QByteArray buildMdnsResponse(uint16_t transactionId, const QHostAddress& targetAddr,
                                 const QString& serviceType, uint16_t port);
    QByteArray buildBrowseQuery();
    QByteArray buildTargetedQuery(const QString& name, uint16_t qtype);
    void sendTargetedQuery(const QString& name, uint16_t qtype);
    void tryCompleteService(const QString& instanceKey);
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
    /// Invite port for `_bettercast-sender._tcp`, or 0 when not advertising as a sender.
    uint16_t m_senderInvitePort = 0;
    QString m_serviceName;
    bool m_advertising = false;
    int m_announceCount = 0;

    // Browsing
    //
    // Records for one service do not have to arrive together. Apple's responder packs
    // PTR, SRV and A into a single datagram, which is why Macs and iPhones were always
    // found; other responders (Android's among them) may answer the PTR first and send
    // SRV or the address records separately, or send AAAA and no A at all. Holding the
    // fragments here and completing a service once its pieces have all turned up is
    // what makes those devices visible.
    struct PendingService {
        QString display;      // "Pixel 8"
        QString hostTarget;   // "pixel-8.local"
        uint16_t port = 0;
    };

    QTimer* m_browseTimer = nullptr;
    bool m_browsing = false;
    QList<DiscoveredService> m_discovered;
    /// Keyed by the lowercased full instance name, e.g. "pixel 8._bettercast._tcp.local".
    QHash<QString, PendingService> m_pending;
    /// Keyed by lowercased host name; IPv4 wins, IPv6 is kept only as a fallback.
    QHash<QString, QHostAddress> m_hostAddrs;
};
