#pragma once

#include <QObject>
#include <QString>
#include <QList>

// mDNS service discovery abstraction.
// Uses Bonjour SDK on Windows, Avahi on Linux.
// Falls back to manual connection if mDNS is unavailable.

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

    // Browse for BetterCast senders
    void startBrowsing();
    void stopBrowsing();

signals:
    void serviceFound(const DiscoveredService& service);
    void serviceLost(const QString& name);

private:
#ifdef HAS_MDNS
    // Platform-specific handles
    void* m_registerRef = nullptr;
    void* m_browseRef = nullptr;
#endif
};
