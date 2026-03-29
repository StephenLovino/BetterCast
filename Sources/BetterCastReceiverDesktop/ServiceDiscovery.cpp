#include "ServiceDiscovery.h"
#include <QDebug>
#include <QNetworkInterface>
#include <QHostInfo>
#include <QtEndian>
#include <QVariant>

#ifdef HAS_MDNS
#include <dns_sd.h>
#ifdef __linux__
#include <arpa/inet.h>  // htons
#endif
#endif

// mDNS constants
static const QHostAddress kMdnsAddress("224.0.0.251");
static const uint16_t kMdnsPort = 5353;

// DNS record types
static const uint16_t kTypePTR = 12;
static const uint16_t kTypeSRV = 33;
static const uint16_t kTypeTXT = 16;
static const uint16_t kTypeA   = 1;
static const uint16_t kClassIN = 1;
static const uint16_t kClassFlush = 0x8001; // Cache flush + IN

ServiceDiscovery::ServiceDiscovery(QObject* parent)
    : QObject(parent)
{
}

ServiceDiscovery::~ServiceDiscovery() {
    stopAdvertising();
    stopBrowsing();
}

QString ServiceDiscovery::getHostname() {
    QString hostname = QHostInfo::localHostName();
    if (hostname.isEmpty()) hostname = "BetterCast-Receiver";
    return hostname;
}

QList<QHostAddress> ServiceDiscovery::getLocalAddresses() {
    QList<QHostAddress> result;
    for (const auto& iface : QNetworkInterface::allInterfaces()) {
        if (iface.flags().testFlag(QNetworkInterface::IsUp) &&
            iface.flags().testFlag(QNetworkInterface::IsRunning) &&
            !iface.flags().testFlag(QNetworkInterface::IsLoopBack)) {
            for (const auto& entry : iface.addressEntries()) {
                if (entry.ip().protocol() == QAbstractSocket::IPv4Protocol) {
                    result.append(entry.ip());
                }
            }
        }
    }
    return result;
}

void ServiceDiscovery::startAdvertising(uint16_t tcpPort) {
#ifdef HAS_MDNS
    // Use system Bonjour/Avahi if available
    DNSServiceRef ref = nullptr;
    DNSServiceErrorType err = DNSServiceRegister(
        &ref, 0, 0, "BetterCast Receiver", "_bettercast._tcp",
        nullptr, nullptr, htons(tcpPort), 0, nullptr, nullptr, nullptr);
    if (err == kDNSServiceErr_NoError) {
        m_registerRef = ref;
        qDebug() << "mDNS: Advertising via system Bonjour on port" << tcpPort;
        return;
    }
#endif

    // Embedded mDNS responder — no external dependencies needed
    m_advertisedPort = tcpPort;
#ifdef _WIN32
    m_serviceName = "BetterCast Receiver Windows";
#else
    m_serviceName = "BetterCast Receiver Linux";
#endif
    m_advertising = true;
    m_announceCount = 0;

    m_mdnsSocket = new QUdpSocket(this);

    // Bind to mDNS multicast port, allow port sharing
    if (!m_mdnsSocket->bind(QHostAddress::AnyIPv4, kMdnsPort,
                            QUdpSocket::ShareAddress | QUdpSocket::ReuseAddressHint)) {
        qWarning() << "mDNS: Failed to bind to port 5353:" << m_mdnsSocket->errorString()
                   << "— will send announcements only (no query responses)";
        // Try without share (some Windows configs — DNS Client service holds 5353)
        if (!m_mdnsSocket->bind(QHostAddress::AnyIPv4, 0)) {
            qWarning() << "mDNS: Failed to bind to any port:" << m_mdnsSocket->errorString();
            delete m_mdnsSocket;
            m_mdnsSocket = nullptr;
            return;
        }
        qDebug() << "mDNS: Bound to fallback port" << m_mdnsSocket->localPort()
                 << "— announcements will be sent every 5s";
    }

    // Join multicast group on all interfaces
    bool joined = false;
    for (const auto& iface : QNetworkInterface::allInterfaces()) {
        if (iface.flags().testFlag(QNetworkInterface::IsUp) &&
            iface.flags().testFlag(QNetworkInterface::IsRunning) &&
            iface.flags().testFlag(QNetworkInterface::CanMulticast) &&
            !iface.flags().testFlag(QNetworkInterface::IsLoopBack)) {
            if (m_mdnsSocket->joinMulticastGroup(kMdnsAddress, iface)) {
                joined = true;
                qDebug() << "mDNS: Joined multicast on" << iface.humanReadableName();
            }
        }
    }

    if (!joined) {
        // Fallback: join without specifying interface
        m_mdnsSocket->joinMulticastGroup(kMdnsAddress);
    }

    m_mdnsSocket->setSocketOption(QAbstractSocket::MulticastTtlOption, QVariant(255));

    connect(m_mdnsSocket, &QUdpSocket::readyRead, this, &ServiceDiscovery::onMdnsReadyRead);

    // Send gratuitous announcement so the Mac sender discovers us immediately
    m_announceTimer = new QTimer(this);
    connect(m_announceTimer, &QTimer::timeout, this, &ServiceDiscovery::sendAnnouncement);
    // Announce frequently at startup (every 1s for first 5), then every 20s
    // macOS NWBrowser needs to see announcements within its browse window
    m_announceTimer->start(1000);
    sendAnnouncement();

    auto addrs = getLocalAddresses();
    qDebug() << "mDNS: Advertising" << m_serviceName << "on port" << tcpPort
             << "IPs:" << addrs;
}

void ServiceDiscovery::stopAdvertising() {
#ifdef HAS_MDNS
    if (m_registerRef) {
        DNSServiceRefDeallocate(static_cast<DNSServiceRef>(m_registerRef));
        m_registerRef = nullptr;
    }
#endif

    m_advertising = false;
    if (m_announceTimer) {
        m_announceTimer->stop();
        delete m_announceTimer;
        m_announceTimer = nullptr;
    }
    if (m_mdnsSocket) {
        m_mdnsSocket->close();
        delete m_mdnsSocket;
        m_mdnsSocket = nullptr;
    }
}

void ServiceDiscovery::startBrowsing() {
    qDebug() << "mDNS browsing not needed — sender browses for us";
}

void ServiceDiscovery::stopBrowsing() {
#ifdef HAS_MDNS
    if (m_browseRef) {
        DNSServiceRefDeallocate(static_cast<DNSServiceRef>(m_browseRef));
        m_browseRef = nullptr;
    }
#endif
}

void ServiceDiscovery::onMdnsReadyRead() {
    while (m_mdnsSocket && m_mdnsSocket->hasPendingDatagrams()) {
        QByteArray data;
        data.resize(static_cast<int>(m_mdnsSocket->pendingDatagramSize()));
        QHostAddress sender;
        uint16_t senderPort;
        m_mdnsSocket->readDatagram(data.data(), data.size(), &sender, &senderPort);

        if (m_advertising) {
            handleMdnsQuery(data, sender, senderPort);
        }
    }
}

void ServiceDiscovery::handleMdnsQuery(const QByteArray& packet,
                                        const QHostAddress& sender,
                                        uint16_t senderPort) {
    // Minimal DNS query parser — we only care about queries for _bettercast._tcp.local
    if (packet.size() < 12) return;

    const uint8_t* d = reinterpret_cast<const uint8_t*>(packet.constData());

    uint16_t txId = qFromBigEndian<uint16_t>(d);
    uint16_t flags = qFromBigEndian<uint16_t>(d + 2);

    // Only respond to queries (QR bit = 0)
    if (flags & 0x8000) return;

    uint16_t qdCount = qFromBigEndian<uint16_t>(d + 4);
    if (qdCount == 0) return;

    // Parse the question section to check if it's asking about our service
    int offset = 12;
    for (int q = 0; q < qdCount && offset < packet.size(); q++) {
        // Read the DNS name
        QString qname;
        while (offset < packet.size()) {
            uint8_t labelLen = static_cast<uint8_t>(d[offset]);
            if (labelLen == 0) {
                offset++;
                break;
            }
            if (labelLen >= 0xC0) {
                offset += 2; // Compressed pointer, skip
                break;
            }
            offset++;
            if (offset + labelLen > packet.size()) return;
            if (!qname.isEmpty()) qname += ".";
            qname += QString::fromUtf8(reinterpret_cast<const char*>(d + offset), labelLen);
            offset += labelLen;
        }

        if (offset + 4 > packet.size()) return;
        uint16_t qtype = qFromBigEndian<uint16_t>(d + offset);
        offset += 4; // skip qtype + qclass

        // Check if this query is for our service type or a general service browse
        if (qname.contains("_bettercast._tcp") ||
            (qtype == kTypePTR && qname.contains("_services._dns-sd")) ||
            (qtype == kTypePTR && qname.contains("_tcp.local"))) {
            // Send our response
            auto addrs = getLocalAddresses();
            for (const auto& addr : addrs) {
                QByteArray response = buildMdnsResponse(txId, addr);
                m_mdnsSocket->writeDatagram(response, kMdnsAddress, kMdnsPort);
            }
            return;
        }
    }
}

void ServiceDiscovery::sendAnnouncement() {
    if (!m_mdnsSocket || !m_advertising) return;

    m_announceCount++;

    // After initial burst (5 announcements at 1s), slow to every 5s
    // 5s keeps us reliably visible in macOS NWBrowser's cache
    // (20s was too long — macOS mDNSResponder would drop us between announcements)
    if (m_announceCount == 5 && m_announceTimer) {
        m_announceTimer->setInterval(5000);
    }

    auto addrs = getLocalAddresses();
    for (const auto& addr : addrs) {
        QByteArray response = buildMdnsResponse(0, addr);
        m_mdnsSocket->writeDatagram(response, kMdnsAddress, kMdnsPort);
    }
}

QByteArray ServiceDiscovery::encodeDnsName(const QString& name) {
    QByteArray result;
    QStringList parts = name.split('.');
    for (const auto& part : parts) {
        QByteArray utf8 = part.toUtf8();
        result.append(static_cast<char>(utf8.size()));
        result.append(utf8);
    }
    result.append('\0');
    return result;
}

QByteArray ServiceDiscovery::buildMdnsResponse(uint16_t transactionId,
                                                const QHostAddress& targetAddr) {
    QByteArray pkt;
    QString hostname = getHostname();
    QString instanceName = m_serviceName;    // "BetterCast Receiver"
    QString serviceType = "_bettercast._tcp.local";
    QString fullName = instanceName + "." + serviceType;
    QString hostTarget = hostname + ".local";

    // DNS Header (response, authoritative)
    uint16_t txId = qToBigEndian(transactionId);
    uint16_t flags = qToBigEndian(static_cast<uint16_t>(0x8400)); // Response + Authoritative
    uint16_t qdCount = 0;
    uint16_t anCount = qToBigEndian(static_cast<uint16_t>(4)); // PTR + SRV + TXT + A
    uint16_t nsCount = 0;
    uint16_t arCount = 0;

    pkt.append(reinterpret_cast<const char*>(&txId), 2);
    pkt.append(reinterpret_cast<const char*>(&flags), 2);
    pkt.append(reinterpret_cast<const char*>(&qdCount), 2);
    pkt.append(reinterpret_cast<const char*>(&anCount), 2);
    pkt.append(reinterpret_cast<const char*>(&nsCount), 2);
    pkt.append(reinterpret_cast<const char*>(&arCount), 2);

    // Record helper: [name][type:2][class:2][ttl:4][rdlength:2][rdata]
    auto appendU16 = [&pkt](uint16_t v) {
        uint16_t be = qToBigEndian(v);
        pkt.append(reinterpret_cast<const char*>(&be), 2);
    };
    auto appendU32 = [&pkt](uint32_t v) {
        uint32_t be = qToBigEndian(v);
        pkt.append(reinterpret_cast<const char*>(&be), 4);
    };

    uint32_t ttl = 120; // 2 minutes

    // 1. PTR record: _bettercast._tcp.local → BetterCast Receiver._bettercast._tcp.local
    pkt.append(encodeDnsName(serviceType));
    appendU16(kTypePTR);
    appendU16(kClassIN);
    appendU32(ttl);
    QByteArray ptrRdata = encodeDnsName(fullName);
    appendU16(static_cast<uint16_t>(ptrRdata.size()));
    pkt.append(ptrRdata);

    // 2. SRV record: BetterCast Receiver._bettercast._tcp.local → hostname.local:port
    pkt.append(encodeDnsName(fullName));
    appendU16(kTypeSRV);
    appendU16(kClassFlush);
    appendU32(ttl);
    QByteArray srvTarget = encodeDnsName(hostTarget);
    uint16_t srvRdataLen = 6 + static_cast<uint16_t>(srvTarget.size()); // priority + weight + port + target
    appendU16(srvRdataLen);
    appendU16(0);   // priority
    appendU16(0);   // weight
    appendU16(m_advertisedPort); // port
    pkt.append(srvTarget);

    // 3. TXT record: empty (required by mDNS spec)
    pkt.append(encodeDnsName(fullName));
    appendU16(kTypeTXT);
    appendU16(kClassFlush);
    appendU32(ttl);
    appendU16(1);   // rdlength = 1 (single empty string)
    pkt.append('\0');

    // 4. A record: hostname.local → IP address
    pkt.append(encodeDnsName(hostTarget));
    appendU16(kTypeA);
    appendU16(kClassFlush);
    appendU32(ttl);
    appendU16(4);   // rdlength = 4 bytes for IPv4
    quint32 ipv4 = targetAddr.toIPv4Address();
    uint32_t ipBe = qToBigEndian(ipv4);
    pkt.append(reinterpret_cast<const char*>(&ipBe), 4);

    return pkt;
}
