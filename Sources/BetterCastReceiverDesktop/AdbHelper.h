#pragma once

#include <QObject>
#include <QString>
#include <QProcess>

class AdbHelper : public QObject {
    Q_OBJECT

public:
    explicit AdbHelper(QObject* parent = nullptr);

    /// Find adb binary on the system. Returns empty string if not found.
    QString findAdb();

    /// Run `adb forward tcp:port tcp:port` and return success.
    /// Also enables wireless ADB so the connection survives USB disconnect.
    bool setupForward(uint16_t port);

    /// Run `adb devices` and return the best serial (prefers USB over WiFi).
    /// Returns empty string if only one device (adb picks automatically).
    QString findDevice();

    /// Check if adb is available
    bool isAvailable() { return !findAdb().isEmpty(); }

    /// Get the device IP for wireless ADB (empty if not known)
    QString deviceIp() const { return m_deviceIp; }

    /// Whether the last connection used ADB (for auto-reconnect decisions)
    bool wasAdbConnection() const { return m_wasAdbConnection; }

    /// Last port used for forward
    uint16_t lastPort() const { return m_lastPort; }

    /// Enable wireless ADB (call AFTER streaming connection is established).
    /// Runs adb tcpip 5555 + adb connect, which temporarily drops USB.
    bool enableWirelessAdb();

signals:
    void statusChanged(const QString& status);

private:
    QString runAdb(const QStringList& args, int timeoutMs = 10000);
    QString getDeviceIp();

    QString m_adbPath;
    QString m_deviceSerial;
    QString m_deviceIp;
    uint16_t m_lastPort = 0;
    bool m_wasAdbConnection = false;
};
