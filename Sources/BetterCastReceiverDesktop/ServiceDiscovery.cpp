#include "ServiceDiscovery.h"
#include "MainWindow.h"  // for LogManager
#include <QDebug>
#include <QNetworkInterface>
#include <QHostInfo>
#include <QStringList>
#include <QtEndian>
#include <QVariant>
#include <cstring>

// Log to both qDebug and the app's visible log viewer
#define MDNS_LOG(msg) do { \
    QString _m = (msg); \
    qDebug().noquote() << _m; \
    LogManager::instance().log(_m); \
} while(0)

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
static const uint16_t kTypeAAAA = 28;
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
    QString hostname = QSysInfo::machineHostName();
#ifdef _WIN32
    QString svcStr = (hostname.isEmpty() || hostname == "localhost") ? "Windows PC" : hostname + " (Windows)";
#else
    QString svcStr = (hostname.isEmpty() || hostname == "localhost") ? "Linux PC" : hostname + " (Linux)";
#endif
    QByteArray svcName = svcStr.toUtf8();
    DNSServiceErrorType err = DNSServiceRegister(
        &ref, 0, 0, svcName.constData(), "_bettercast._tcp",
        nullptr, nullptr, htons(tcpPort), 0, nullptr, nullptr, nullptr);
    if (err == kDNSServiceErr_NoError) {
        m_registerRef = ref;
        qDebug() << "mDNS: Advertising via system Bonjour on port" << tcpPort;
        return;
    }
#endif

    // Embedded mDNS responder — use system hostname + platform for device identification
    // Platform keyword is needed so the Mac sender can detect non-Apple receivers
    m_advertisedPort = tcpPort;
    const QString hostName = QSysInfo::machineHostName();
#ifdef _WIN32
    const QString platform = "Windows";
#else
    const QString platform = "Linux";
#endif
    if (hostName.isEmpty() || hostName == "localhost") {
        m_serviceName = platform + " PC";
    } else {
        m_serviceName = hostName + " (" + platform + ")";
    }
    m_advertising = true;
    m_announceCount = 0;

    ensureMdnsSocket();
    if (!m_mdnsSocket) {
        MDNS_LOG("mDNS: FAILED to create socket — auto-discovery will NOT work");
        MDNS_LOG("mDNS: Manual IP connection still works");
        return;
    }

    // Send gratuitous announcement so the Mac sender discovers us immediately
    m_announceTimer = new QTimer(this);
    connect(m_announceTimer, &QTimer::timeout, this, &ServiceDiscovery::sendAnnouncement);
    // Announce frequently at startup (every 500ms for first 20), then every 3s
    m_announceTimer->start(500);
    sendAnnouncement();

    auto addrs = getLocalAddresses();
    QStringList ipStrs;
    for (const auto& a : addrs) ipStrs.append(a.toString());
    MDNS_LOG(QString("mDNS: Advertising \"%1\" on port %2 — IPs: %3")
             .arg(m_serviceName).arg(tcpPort).arg(ipStrs.join(", ")));
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
    if (m_browsing) return;
    m_browsing = true;

    ensureMdnsSocket();

    // Send browse queries periodically
    m_browseTimer = new QTimer(this);
    connect(m_browseTimer, &QTimer::timeout, this, &ServiceDiscovery::sendBrowseQuery);
    m_browseTimer->start(3000); // every 3 seconds
    sendBrowseQuery(); // immediate first query

    MDNS_LOG("mDNS: Started browsing for _bettercast._tcp receivers");
}

void ServiceDiscovery::stopBrowsing() {
    m_browsing = false;
    if (m_browseTimer) {
        m_browseTimer->stop();
        delete m_browseTimer;
        m_browseTimer = nullptr;
    }
    m_discovered.clear();
    m_pending.clear();
    m_hostAddrs.clear();

#ifdef HAS_MDNS
    if (m_browseRef) {
        DNSServiceRefDeallocate(static_cast<DNSServiceRef>(m_browseRef));
        m_browseRef = nullptr;
    }
#endif
}

void ServiceDiscovery::ensureMdnsSocket() {
    if (m_mdnsSocket) return;

    m_mdnsSocket = new QUdpSocket(this);

    // Try binding to port 5353 — needed to receive mDNS queries from other devices
    bool boundTo5353 = m_mdnsSocket->bind(QHostAddress::AnyIPv4, kMdnsPort,
                                           QUdpSocket::ShareAddress | QUdpSocket::ReuseAddressHint);
    if (boundTo5353) {
        MDNS_LOG("mDNS: Bound to port 5353 (can receive queries)");
    } else {
        MDNS_LOG(QString("mDNS: Could not bind port 5353: %1").arg(m_mdnsSocket->errorString()));
        // Fallback: bind to any port (we can still send announcements but can't receive queries)
        if (!m_mdnsSocket->bind(QHostAddress::AnyIPv4, 0)) {
            MDNS_LOG(QString("mDNS: Failed to bind ANY port: %1").arg(m_mdnsSocket->errorString()));
            delete m_mdnsSocket;
            m_mdnsSocket = nullptr;
            return;
        }
        MDNS_LOG(QString("mDNS: Bound to fallback port %1 (send-only)").arg(m_mdnsSocket->localPort()));
    }

    // Join multicast group on all eligible interfaces
    bool joined = false;
    for (const auto& iface : QNetworkInterface::allInterfaces()) {
        if (iface.flags().testFlag(QNetworkInterface::IsUp) &&
            iface.flags().testFlag(QNetworkInterface::IsRunning) &&
            iface.flags().testFlag(QNetworkInterface::CanMulticast) &&
            !iface.flags().testFlag(QNetworkInterface::IsLoopBack)) {
            if (m_mdnsSocket->joinMulticastGroup(kMdnsAddress, iface)) {
                MDNS_LOG(QString("mDNS: Joined multicast on %1").arg(iface.humanReadableName()));
                joined = true;
            } else {
                MDNS_LOG(QString("mDNS: Failed multicast join on %1: %2")
                         .arg(iface.humanReadableName(), m_mdnsSocket->errorString()));
            }
        }
    }
    if (!joined) {
        if (m_mdnsSocket->joinMulticastGroup(kMdnsAddress)) {
            MDNS_LOG("mDNS: Joined multicast on default interface");
            joined = true;
        } else {
            MDNS_LOG("mDNS: FAILED to join any multicast group — discovery will not work");
        }
    }

    m_mdnsSocket->setSocketOption(QAbstractSocket::MulticastTtlOption, QVariant(255));
    m_mdnsSocket->setSocketOption(QAbstractSocket::MulticastLoopbackOption, QVariant(1));
    connect(m_mdnsSocket, &QUdpSocket::readyRead, this, &ServiceDiscovery::onMdnsReadyRead);
}

bool ServiceDiscovery::isOwnAddress(const QHostAddress& addr) {
    for (const auto& local : getLocalAddresses()) {
        if (local == addr) return true;
    }
    return false;
}

void ServiceDiscovery::sendBrowseQuery() {
    if (!m_mdnsSocket) return;

    QByteArray query = buildBrowseQuery();
    m_mdnsSocket->writeDatagram(query, kMdnsAddress, kMdnsPort);
}

QByteArray ServiceDiscovery::buildBrowseQuery() {
    QByteArray pkt;

    // DNS header: standard query
    uint16_t zero = 0;
    uint16_t qdCount = qToBigEndian(static_cast<uint16_t>(1));
    pkt.append(reinterpret_cast<const char*>(&zero), 2);   // Transaction ID
    pkt.append(reinterpret_cast<const char*>(&zero), 2);   // Flags (query)
    pkt.append(reinterpret_cast<const char*>(&qdCount), 2); // Questions: 1
    pkt.append(reinterpret_cast<const char*>(&zero), 2);   // Answer RRs
    pkt.append(reinterpret_cast<const char*>(&zero), 2);   // Authority RRs
    pkt.append(reinterpret_cast<const char*>(&zero), 2);   // Additional RRs

    // Question: _bettercast._tcp.local PTR IN
    pkt.append(encodeDnsName("_bettercast._tcp.local"));
    uint16_t ptrType = qToBigEndian(kTypePTR);
    uint16_t classIN = qToBigEndian(kClassIN);
    pkt.append(reinterpret_cast<const char*>(&ptrType), 2);
    pkt.append(reinterpret_cast<const char*>(&classIN), 2);

    return pkt;
}

QString ServiceDiscovery::decodeDnsName(const QByteArray& packet, int& offset) {
    QString name;
    const uint8_t* d = reinterpret_cast<const uint8_t*>(packet.constData());
    int pktSize = packet.size();
    int jumps = 0;
    bool jumped = false;
    int savedOffset = -1;

    while (offset < pktSize && jumps < 10) {
        uint8_t len = d[offset];
        if (len == 0) {
            offset++;
            break;
        }
        if ((len & 0xC0) == 0xC0) {
            // DNS name compression pointer
            if (offset + 1 >= pktSize) break;
            if (!jumped) savedOffset = offset + 2;
            offset = ((len & 0x3F) << 8) | d[offset + 1];
            jumped = true;
            jumps++;
            continue;
        }
        offset++;
        if (offset + len > pktSize) break;
        if (!name.isEmpty()) name += ".";
        name += QString::fromUtf8(reinterpret_cast<const char*>(d + offset), len);
        offset += len;
    }

    if (jumped && savedOffset >= 0) offset = savedOffset;
    return name;
}

void ServiceDiscovery::handleMdnsResponse(const QByteArray& packet) {
    if (packet.size() < 12) return;
    const uint8_t* d = reinterpret_cast<const uint8_t*>(packet.constData());

    uint16_t flags = qFromBigEndian<uint16_t>(d + 2);
    if (!(flags & 0x8000)) return; // Not a response

    uint16_t qdCount = qFromBigEndian<uint16_t>(d + 4);
    uint16_t anCount = qFromBigEndian<uint16_t>(d + 6);

    int offset = 12;

    // Skip questions
    for (int i = 0; i < qdCount && offset < packet.size(); i++) {
        decodeDnsName(packet, offset);
        offset += 4; // skip qtype + qclass
    }

    // Fold every record in the packet into the pending table. Nothing is required to
    // arrive together: a PTR on its own is enough to start tracking an instance, and
    // the SRV or address record that completes it may come in a later datagram or in
    // reply to the targeted query we send below.
    int totalRecords = anCount +
        qFromBigEndian<uint16_t>(d + 8) +  // authority
        qFromBigEndian<uint16_t>(d + 10);   // additional

    QStringList touched;

    for (int i = 0; i < totalRecords && offset + 10 < packet.size(); i++) {
        QString rrName = decodeDnsName(packet, offset);
        if (offset + 10 > packet.size()) break;

        uint16_t rrType = qFromBigEndian<uint16_t>(d + offset);
        offset += 2;
        offset += 2; // class
        offset += 4; // TTL
        uint16_t rdLen = qFromBigEndian<uint16_t>(d + offset);
        offset += 2;

        int rdEnd = offset + rdLen;
        if (rdEnd > packet.size()) break;

        if (rrType == kTypePTR && rrName.contains("_bettercast._tcp")) {
            int p = offset;
            QString full = decodeDnsName(packet, p);
            if (!full.isEmpty()) {
                QString key = full.toLower();
                PendingService& svc = m_pending[key];
                if (svc.display.isEmpty()) {
                    QString display = full;
                    int idx = display.indexOf("._bettercast._tcp");
                    if (idx > 0) display = display.left(idx);
                    svc.display = display;
                }
                touched.append(key);
            }
        } else if (rrType == kTypeSRV && rrName.contains("_bettercast._tcp")) {
            // Key the SRV to its own owner name. The old code took whatever SRV came
            // last in the packet, so a device advertising more than one instance (the
            // iPhone advertises a P2P variant alongside the plain one) could be paired
            // with the wrong port.
            if (rdLen >= 6) {
                int p = offset + 4;  // skip priority + weight
                uint16_t port = qFromBigEndian<uint16_t>(d + p);
                p += 2;
                QString target = decodeDnsName(packet, p);

                QString key = rrName.toLower();
                PendingService& svc = m_pending[key];
                svc.port = port;
                svc.hostTarget = target;
                if (svc.display.isEmpty()) {
                    QString display = rrName;
                    int idx = display.indexOf("._bettercast._tcp");
                    if (idx > 0) display = display.left(idx);
                    svc.display = display;
                }
                touched.append(key);
            }
        } else if (rrType == kTypeA && rdLen == 4) {
            quint32 ip = qFromBigEndian<quint32>(d + offset);
            m_hostAddrs.insert(rrName.toLower(), QHostAddress(ip));
        } else if (rrType == kTypeAAAA && rdLen == 16) {
            // Keep IPv6 only as a fallback. Link-local addresses need a scope id we do
            // not have here, so an IPv4 record for the same host always wins.
            QString key = rrName.toLower();
            Q_IPV6ADDR raw;
            memcpy(&raw, d + offset, 16);
            QHostAddress v6(raw);
            auto existing = m_hostAddrs.constFind(key);
            bool haveV4 = existing != m_hostAddrs.constEnd() &&
                          existing->protocol() == QAbstractSocket::IPv4Protocol;
            if (!haveV4 && !v6.isLinkLocal()) m_hostAddrs.insert(key, v6);
        }

        offset = rdEnd;
    }

    // Every instance this packet mentioned may now be complete — or may need chasing.
    touched.removeDuplicates();
    for (const QString& key : touched) {
        tryCompleteService(key);
    }
}

/// Emit [instanceKey] if we now know its port and address, or ask for what is missing.
void ServiceDiscovery::tryCompleteService(const QString& instanceKey) {
    auto it = m_pending.find(instanceKey);
    if (it == m_pending.end()) return;
    PendingService& svc = it.value();

    if (svc.port == 0) {
        // A PTR with no SRV yet. The old code logged that it was sending a follow-up
        // query and then did not send one, so anything that answered in two packets was
        // simply never discovered.
        MDNS_LOG(QString("mDNS: Got PTR for '%1' but no SRV yet — querying").arg(svc.display));
        sendTargetedQuery(instanceKey, kTypeSRV);
        return;
    }

    QString hostKey = svc.hostTarget.toLower();
    QHostAddress addr = m_hostAddrs.value(hostKey);
    if (addr.isNull()) {
        MDNS_LOG(QString("mDNS: '%1' resolves to %2 but no address record yet — querying")
                     .arg(svc.display, svc.hostTarget));
        sendTargetedQuery(svc.hostTarget, kTypeA);
        return;
    }

    // Skip our own service
    if (isOwnAddress(addr) && svc.port == m_advertisedPort) return;

    DiscoveredService found;
    found.name = svc.display;
    found.host = addr.toString();
    found.port = svc.port;

    for (auto& existing : m_discovered) {
        if (existing.name == found.name) {
            if (existing.host == found.host && existing.port == found.port) return;
            existing.host = found.host;
            existing.port = found.port;
            return;
        }
    }

    m_discovered.append(found);
    MDNS_LOG(QString("Discovered receiver: %1 at %2:%3 (from mDNS SRV record)")
                 .arg(found.name, found.host).arg(found.port));
    if (found.port != 51820) {
        MDNS_LOG(QString("NOTE: Receiver port %1 differs from default 51820 — "
                         "verify receiver is actually listening on this port")
                     .arg(found.port));
    }
    emit serviceFound(found);
}

QByteArray ServiceDiscovery::buildTargetedQuery(const QString& name, uint16_t qtype) {
    QByteArray pkt;
    uint16_t zero = 0;
    uint16_t qdCount = qToBigEndian(static_cast<uint16_t>(1));
    pkt.append(reinterpret_cast<const char*>(&zero), 2);
    pkt.append(reinterpret_cast<const char*>(&zero), 2);
    pkt.append(reinterpret_cast<const char*>(&qdCount), 2);
    pkt.append(reinterpret_cast<const char*>(&zero), 2);
    pkt.append(reinterpret_cast<const char*>(&zero), 2);
    pkt.append(reinterpret_cast<const char*>(&zero), 2);

    pkt.append(encodeDnsName(name));
    uint16_t t = qToBigEndian(qtype);
    uint16_t c = qToBigEndian(kClassIN);
    pkt.append(reinterpret_cast<const char*>(&t), 2);
    pkt.append(reinterpret_cast<const char*>(&c), 2);
    return pkt;
}

void ServiceDiscovery::sendTargetedQuery(const QString& name, uint16_t qtype) {
    if (!m_mdnsSocket || name.isEmpty()) return;
    QByteArray q = buildTargetedQuery(name, qtype);
    m_mdnsSocket->writeDatagram(q, kMdnsAddress, kMdnsPort);
}

void ServiceDiscovery::onMdnsReadyRead() {
    while (m_mdnsSocket && m_mdnsSocket->hasPendingDatagrams()) {
        QByteArray data;
        data.resize(static_cast<int>(m_mdnsSocket->pendingDatagramSize()));
        QHostAddress sender;
        uint16_t senderPort;
        m_mdnsSocket->readDatagram(data.data(), data.size(), &sender, &senderPort);

        // Skip our own announcements
        if (isOwnAddress(sender)) continue;

        if (data.size() < 12) continue;

        uint16_t flags = qFromBigEndian<uint16_t>(
            reinterpret_cast<const uint8_t*>(data.constData()) + 2);

        if (flags & 0x8000) {
            // Response — handle for browsing
            if (m_browsing) {
                handleMdnsResponse(data);
            }
        } else {
            // Query — handle for advertising
            if (m_advertising) {
                handleMdnsQuery(data, sender, senderPort);
            }
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

        // Work out which of our services this question is actually about. Answering a
        // `_bettercast-sender._tcp` browse with the receiver's records — which is what
        // the old catch-all did — tells the phone nothing it can use, so the Windows
        // machine stayed absent from its sender list.
        const bool asksSender = qname.contains("_bettercast-sender._tcp");
        const bool asksReceiver = !asksSender && qname.contains("_bettercast._tcp");
        const bool asksGeneric = qtype == kTypePTR &&
                                 (qname.contains("_services._dns-sd") ||
                                  qname.contains("_tcp.local"));

        if (asksSender || asksReceiver || asksGeneric) {
            auto addrs = getLocalAddresses();
            // Only log BetterCast-specific queries; skip noisy general browse traffic
            if (asksSender || asksReceiver) {
                MDNS_LOG(QString("mDNS: Query for %1 from %2:%3 — responding")
                         .arg(qname, sender.toString()).arg(senderPort));
            }

            const bool sendReceiverRecords = asksReceiver || asksGeneric;
            const bool sendSenderRecords =
                (asksSender || asksGeneric) && m_senderInvitePort != 0;

            for (const auto& addr : addrs) {
                if (sendReceiverRecords) {
                    QByteArray response = buildMdnsResponse(txId, addr,
                                                            "_bettercast._tcp.local",
                                                            m_advertisedPort);
                    // Send to multicast (standard mDNS)
                    m_mdnsSocket->writeDatagram(response, kMdnsAddress, kMdnsPort);
                    // Also send unicast directly to the querier — this works even if
                    // multicast is blocked by Windows Firewall on the return path
                    m_mdnsSocket->writeDatagram(response, sender, senderPort);
                }
                if (sendSenderRecords) {
                    QByteArray response = buildMdnsResponse(txId, addr,
                                                            "_bettercast-sender._tcp.local",
                                                            m_senderInvitePort);
                    m_mdnsSocket->writeDatagram(response, kMdnsAddress, kMdnsPort);
                    m_mdnsSocket->writeDatagram(response, sender, senderPort);
                }
            }
            return;
        }
    }
}

void ServiceDiscovery::sendAnnouncement() {
    if (!m_mdnsSocket || !m_advertising) return;

    m_announceCount++;

    // After initial burst (20 at 500ms = 10s), slow to every 3s
    if (m_announceCount == 20 && m_announceTimer) {
        m_announceTimer->setInterval(3000);
        MDNS_LOG("mDNS: Announcement burst complete, continuing every 3s");
    }

    auto addrs = getLocalAddresses();
    for (const auto& addr : addrs) {
        QByteArray response = buildMdnsResponse(0, addr, "_bettercast._tcp.local",
                                                m_advertisedPort);
        qint64 sent = m_mdnsSocket->writeDatagram(response, kMdnsAddress, kMdnsPort);
        if (m_announceCount <= 3) {
            qDebug() << "mDNS: Announcement" << m_announceCount
                      << "sent" << sent << "bytes for" << addr.toString();
        }

        if (m_senderInvitePort != 0) {
            QByteArray senderResp = buildMdnsResponse(0, addr, "_bettercast-sender._tcp.local",
                                                      m_senderInvitePort);
            m_mdnsSocket->writeDatagram(senderResp, kMdnsAddress, kMdnsPort);
        }
    }
}

void ServiceDiscovery::advertiseSenderService(uint16_t invitePort) {
    if (m_senderInvitePort == invitePort) return;
    m_senderInvitePort = invitePort;
    ensureMdnsSocket();
    MDNS_LOG(QString("mDNS: Advertising as _bettercast-sender._tcp on port %1").arg(invitePort));
    sendAnnouncement();
}

void ServiceDiscovery::stopAdvertisingSenderService() {
    m_senderInvitePort = 0;
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
                                                const QHostAddress& targetAddr,
                                                const QString& serviceType,
                                                uint16_t port) {
    QByteArray pkt;
    QString hostname = getHostname();
    QString instanceName = m_serviceName;    // "BetterCast Receiver"
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
    appendU16(port);
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
