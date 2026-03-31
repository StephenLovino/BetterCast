#pragma once
// Note: this file is only compiled on Windows (gated by ENABLE_SENDER + WIN32).

#include <QObject>
#include <QString>
#include <QSize>
#include <QVector>

// Manages Virtual Display Driver (VDD) integration.
// Detects VDD installation, creates/removes virtual monitors,
// and enumerates available DXGI outputs for capture selection.
class VirtualDisplayVDD : public QObject {
    Q_OBJECT
public:
    explicit VirtualDisplayVDD(QObject* parent = nullptr);
    ~VirtualDisplayVDD() override;

    struct MonitorInfo {
        int adapterIndex;
        int outputIndex;
        QString name;        // e.g. "\\.\DISPLAY1"
        QString adapterName; // e.g. "NVIDIA GeForce RTX 3080"
        int width;
        int height;
        bool isVirtual;      // true if this is a VDD virtual display
    };

    struct VddResolution {
        int width;
        int height;
        int refreshRate;
    };

    // VDD detection
    bool isVddInstalled() const;
    QString vddInstallPath() const;
    void refreshInstallStatus();  // re-run detection (e.g. after user installs VDD)

    // Virtual display management
    bool createVirtualDisplay(int width = 1920, int height = 1080, int refreshRate = 60);
    bool removeVirtualDisplay(int index = -1); // -1 = remove last
    bool removeAllVirtualDisplays();
    int virtualDisplayCount() const;

    // Monitor enumeration (all monitors — real + virtual)
    QVector<MonitorInfo> enumerateMonitors() const;

    // Find the output index for a virtual display
    int findVirtualDisplayOutput() const;

signals:
    void virtualDisplayCreated(int outputIndex);
    void virtualDisplayRemoved();
    void error(const QString& message);
    void statusChanged(const QString& status);

private:
    bool detectVddInstall();
    bool isDriverLoaded() const;
    bool installDriver();
    bool writeVddSettings(const QVector<VddResolution>& displays);
    QVector<VddResolution> readVddSettings() const;
    bool notifyDriverRefresh();
    bool tryNamedPipe(const QString& command);

    QString m_vddPath;
    bool m_vddInstalled = false;
    int m_createdDisplayCount = 0;
};
