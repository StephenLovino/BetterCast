#include "ServiceDiscovery.h"
#include <QDebug>

#ifdef HAS_MDNS
// Bonjour SDK (Windows) or Avahi compat layer (Linux)
#include <dns_sd.h>
#endif

ServiceDiscovery::ServiceDiscovery(QObject* parent)
    : QObject(parent)
{
}

ServiceDiscovery::~ServiceDiscovery() {
    stopAdvertising();
    stopBrowsing();
}

void ServiceDiscovery::startAdvertising(uint16_t tcpPort) {
#ifdef HAS_MDNS
    DNSServiceRef ref = nullptr;
    DNSServiceErrorType err = DNSServiceRegister(
        &ref,
        0,                          // flags
        0,                          // all interfaces
        "BetterCast Receiver",      // name
        "_bettercast._tcp",         // type (matches Swift sender)
        nullptr,                    // domain (default)
        nullptr,                    // host (default)
        htons(tcpPort),             // port
        0, nullptr,                 // TXT record
        nullptr,                    // callback
        nullptr                     // context
    );

    if (err == kDNSServiceErr_NoError) {
        m_registerRef = ref;
        qDebug() << "mDNS: Advertising on port" << tcpPort;
    } else {
        qWarning() << "mDNS: Failed to register service, error:" << err;
    }
#else
    Q_UNUSED(tcpPort);
    qDebug() << "mDNS not available — use manual connection";
#endif
}

void ServiceDiscovery::stopAdvertising() {
#ifdef HAS_MDNS
    if (m_registerRef) {
        DNSServiceRefDeallocate(static_cast<DNSServiceRef>(m_registerRef));
        m_registerRef = nullptr;
    }
#endif
}

void ServiceDiscovery::startBrowsing() {
#ifdef HAS_MDNS
    // TODO: Implement sender browsing for auto-connect
    // For now, the sender discovers the receiver (not the other way around)
    qDebug() << "mDNS browsing not yet implemented";
#else
    qDebug() << "mDNS not available — use manual connection";
#endif
}

void ServiceDiscovery::stopBrowsing() {
#ifdef HAS_MDNS
    if (m_browseRef) {
        DNSServiceRefDeallocate(static_cast<DNSServiceRef>(m_browseRef));
        m_browseRef = nullptr;
    }
#endif
}
