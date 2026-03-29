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
    bool setupForward(uint16_t port);

    /// Run `adb devices` and return the best serial (prefers USB over WiFi).
    /// Returns empty string if only one device (adb picks automatically).
    QString findDevice();

    /// Check if adb is available
    bool isAvailable() { return !findAdb().isEmpty(); }

signals:
    void statusChanged(const QString& status);

private:
    QString runAdb(const QStringList& args, int timeoutMs = 10000);
    QString m_adbPath;
    QString m_deviceSerial;
};
