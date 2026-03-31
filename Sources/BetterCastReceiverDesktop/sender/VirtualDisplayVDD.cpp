#include "VirtualDisplayVDD.h"

#include <QDebug>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QProcess>
#include <QThread>
#include <QXmlStreamReader>
#include <QXmlStreamWriter>

#ifdef _WIN32
#include <Windows.h>
#include <dxgi.h>
#include <SetupAPI.h>
#include <devguid.h>
#include <cfgmgr32.h>

#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "setupapi.lib")
#endif

// Known VDD installation paths
static const QStringList kVddPaths = {
    "C:/VirtualDisplayDriver",
    "C:/Program Files/Virtual Display Driver",
    "C:/Program Files/VirtualDisplayDriver",
};

// VDD settings file names (varies by version)
static const QStringList kSettingsFiles = {
    "vdd_settings.xml",
    "settings.xml",
    "config.xml",
};

// VDD named pipe (modern versions)
static const char* kVddPipeName = "\\\\.\\pipe\\VDDPipe";

// VDD hardware IDs to look for
static const QStringList kVddHardwareIds = {
    "Root\\VirtualDisplayDriver",
    "Root\\IddSampleDriver",
    "VDD",
};

VirtualDisplayVDD::VirtualDisplayVDD(QObject* parent)
    : QObject(parent)
{
    m_vddInstalled = detectVddInstall();
    if (m_vddInstalled) {
        qDebug() << "VDD: Found installation at" << m_vddPath;
    } else {
        qDebug() << "VDD: Not installed";
    }
}

VirtualDisplayVDD::~VirtualDisplayVDD() {
    // Clean up any virtual displays we created
    if (m_createdDisplayCount > 0) {
        removeAllVirtualDisplays();
    }
}

bool VirtualDisplayVDD::isVddInstalled() const {
    return m_vddInstalled;
}

QString VirtualDisplayVDD::vddInstallPath() const {
    return m_vddPath;
}

bool VirtualDisplayVDD::detectVddInstall() {
    // Method 0: Check BetterCast's own bundled VDD path (set by installer)
#ifdef _WIN32
    {
        HKEY hKey;
        LONG result = RegOpenKeyExW(
            HKEY_LOCAL_MACHINE, L"Software\\BetterCast",
            0, KEY_READ, &hKey);
        if (result == ERROR_SUCCESS) {
            wchar_t vddPath[MAX_PATH] = {};
            DWORD size = sizeof(vddPath);
            result = RegQueryValueExW(hKey, L"VDDPath", nullptr, nullptr,
                                       reinterpret_cast<LPBYTE>(vddPath), &size);
            RegCloseKey(hKey);
            if (result == ERROR_SUCCESS) {
                QString path = QString::fromWCharArray(vddPath);
                if (QDir(path).exists()) {
                    m_vddPath = path;
                    qDebug() << "VDD: Found bundled installation at" << path;
                    return true;
                }
            }
        }
    }
#endif

    // Method 1: Check known installation paths
    for (const auto& basePath : kVddPaths) {
        QDir dir(basePath);
        if (dir.exists()) {
            // Verify there's actually a driver or settings file here
            for (const auto& settingsFile : kSettingsFiles) {
                if (QFileInfo::exists(basePath + "/" + settingsFile)) {
                    m_vddPath = basePath;
                    return true;
                }
            }
            // Check for driver files even without settings
            if (QFileInfo::exists(basePath + "/VirtualDisplayDriver.dll") ||
                QFileInfo::exists(basePath + "/IddSampleDriver.dll")) {
                m_vddPath = basePath;
                return true;
            }
        }
    }

#ifdef _WIN32
    // Method 2: Check registry for VDD driver
    HKEY hKey;
    LONG result = RegOpenKeyExW(
        HKEY_LOCAL_MACHINE,
        L"SYSTEM\\CurrentControlSet\\Services\\VirtualDisplayDriver",
        0, KEY_READ, &hKey);
    if (result == ERROR_SUCCESS) {
        wchar_t imagePath[MAX_PATH] = {};
        DWORD size = sizeof(imagePath);
        result = RegQueryValueExW(hKey, L"ImagePath", nullptr, nullptr,
                                   reinterpret_cast<LPBYTE>(imagePath), &size);
        RegCloseKey(hKey);
        if (result == ERROR_SUCCESS) {
            QString path = QString::fromWCharArray(imagePath);
            QFileInfo fi(path);
            m_vddPath = fi.absolutePath();
            return true;
        }
    }

    // Method 3: Check for VDD device via SetupDI
    HDEVINFO devInfo = SetupDiGetClassDevsW(
        &GUID_DEVCLASS_DISPLAY, nullptr, nullptr,
        DIGCF_PRESENT | DIGCF_ALLCLASSES);
    if (devInfo != INVALID_HANDLE_VALUE) {
        SP_DEVINFO_DATA devData = {};
        devData.cbSize = sizeof(devData);
        for (DWORD i = 0; SetupDiEnumDeviceInfo(devInfo, i, &devData); i++) {
            wchar_t hwId[512] = {};
            if (SetupDiGetDeviceRegistryPropertyW(devInfo, &devData,
                    SPDRP_HARDWAREID, nullptr,
                    reinterpret_cast<PBYTE>(hwId), sizeof(hwId), nullptr)) {
                QString id = QString::fromWCharArray(hwId).toLower();
                for (const auto& vddId : kVddHardwareIds) {
                    if (id.contains(vddId.toLower())) {
                        SetupDiDestroyDeviceInfoList(devInfo);
                        // Try to find the install path from device
                        if (m_vddPath.isEmpty()) {
                            for (const auto& p : kVddPaths) {
                                if (QDir(p).exists()) { m_vddPath = p; break; }
                            }
                        }
                        return true;
                    }
                }
            }
        }
        SetupDiDestroyDeviceInfoList(devInfo);
    }
#endif

    return false;
}

// ─── Virtual Display Management ────────────────────────────────────────────────

bool VirtualDisplayVDD::createVirtualDisplay(int width, int height, int refreshRate) {
    if (!m_vddInstalled) {
        emit error("VDD is not installed. Download from github.com/itsmikethetech/Virtual-Display-Driver");
        return false;
    }

    emit statusChanged(QString("Creating virtual display %1x%2 @ %3Hz...")
                            .arg(width).arg(height).arg(refreshRate));

    // Method 1: Try VDD named pipe (modern versions)
    QString pipeCmd = QString("{\"command\":\"add\",\"width\":%1,\"height\":%2,\"refreshRate\":%3}")
                          .arg(width).arg(height).arg(refreshRate);
    if (tryNamedPipe(pipeCmd)) {
        m_createdDisplayCount++;
        emit statusChanged(QString("Virtual display created: %1x%2 @ %3Hz")
                               .arg(width).arg(height).arg(refreshRate));
        // Wait for Windows to register the new display
        QThread::msleep(1500);
        int outputIdx = findVirtualDisplayOutput();
        emit virtualDisplayCreated(outputIdx);
        return true;
    }

    // Method 2: Modify settings file + notify driver
    auto displays = readVddSettings();
    displays.append({width, height, refreshRate});

    if (!writeVddSettings(displays)) {
        emit error("Failed to write VDD settings file");
        return false;
    }

    if (!notifyDriverRefresh()) {
        emit error("Failed to notify VDD driver — try restarting the driver manually");
        return false;
    }

    m_createdDisplayCount++;
    emit statusChanged(QString("Virtual display created: %1x%2 @ %3Hz")
                           .arg(width).arg(height).arg(refreshRate));

    // Wait for the display to appear
    QThread::msleep(2000);
    int outputIdx = findVirtualDisplayOutput();
    emit virtualDisplayCreated(outputIdx);
    return true;
}

bool VirtualDisplayVDD::removeVirtualDisplay(int index) {
    if (!m_vddInstalled) return false;

    emit statusChanged("Removing virtual display...");

    // Method 1: Try named pipe
    QString pipeCmd;
    if (index >= 0) {
        pipeCmd = QString("{\"command\":\"remove\",\"index\":%1}").arg(index);
    } else {
        pipeCmd = "{\"command\":\"remove\",\"index\":-1}";
    }

    if (tryNamedPipe(pipeCmd)) {
        if (m_createdDisplayCount > 0) m_createdDisplayCount--;
        emit virtualDisplayRemoved();
        emit statusChanged("Virtual display removed");
        return true;
    }

    // Method 2: Modify settings
    auto displays = readVddSettings();
    if (displays.isEmpty()) return false;

    if (index >= 0 && index < displays.size()) {
        displays.remove(index);
    } else {
        displays.removeLast();
    }

    if (!writeVddSettings(displays)) {
        emit error("Failed to update VDD settings");
        return false;
    }

    notifyDriverRefresh();
    if (m_createdDisplayCount > 0) m_createdDisplayCount--;
    emit virtualDisplayRemoved();
    emit statusChanged("Virtual display removed");
    return true;
}

bool VirtualDisplayVDD::removeAllVirtualDisplays() {
    if (!m_vddInstalled) return false;

    // Try named pipe
    if (tryNamedPipe("{\"command\":\"removeAll\"}")) {
        m_createdDisplayCount = 0;
        emit virtualDisplayRemoved();
        return true;
    }

    // Fallback: write empty display list
    if (writeVddSettings({})) {
        notifyDriverRefresh();
        m_createdDisplayCount = 0;
        emit virtualDisplayRemoved();
        return true;
    }

    return false;
}

int VirtualDisplayVDD::virtualDisplayCount() const {
    return m_createdDisplayCount;
}

// ─── Monitor Enumeration ───────────────────────────────────────────────────────

QVector<VirtualDisplayVDD::MonitorInfo> VirtualDisplayVDD::enumerateMonitors() const {
    QVector<MonitorInfo> result;

#ifdef _WIN32
    IDXGIFactory1* factory = nullptr;
    HRESULT hr = CreateDXGIFactory1(__uuidof(IDXGIFactory1), (void**)&factory);
    if (FAILED(hr)) {
        qWarning() << "VDD: CreateDXGIFactory1 failed";
        return result;
    }

    IDXGIAdapter1* adapter = nullptr;
    for (UINT adapterIdx = 0;
         factory->EnumAdapters1(adapterIdx, &adapter) != DXGI_ERROR_NOT_FOUND;
         adapterIdx++) {

        DXGI_ADAPTER_DESC1 adapterDesc;
        adapter->GetDesc1(&adapterDesc);
        QString adapterName = QString::fromWCharArray(adapterDesc.Description);

        IDXGIOutput* output = nullptr;
        for (UINT outputIdx = 0;
             adapter->EnumOutputs(outputIdx, &output) != DXGI_ERROR_NOT_FOUND;
             outputIdx++) {

            DXGI_OUTPUT_DESC outputDesc;
            output->GetDesc(&outputDesc);

            MonitorInfo info;
            info.adapterIndex = static_cast<int>(adapterIdx);
            info.outputIndex = static_cast<int>(outputIdx);
            info.name = QString::fromWCharArray(outputDesc.DeviceName);
            info.adapterName = adapterName;
            info.width = outputDesc.DesktopCoordinates.right - outputDesc.DesktopCoordinates.left;
            info.height = outputDesc.DesktopCoordinates.bottom - outputDesc.DesktopCoordinates.top;

            // Detect virtual displays by adapter name patterns
            QString lowerAdapter = adapterName.toLower();
            info.isVirtual = lowerAdapter.contains("virtual") ||
                             lowerAdapter.contains("indirect") ||
                             lowerAdapter.contains("idd") ||
                             lowerAdapter.contains("vdd");

            result.append(info);
            output->Release();
        }
        adapter->Release();
    }
    factory->Release();
#endif

    return result;
}

int VirtualDisplayVDD::findVirtualDisplayOutput() const {
    auto monitors = enumerateMonitors();
    // Return the last virtual display found (most recently created)
    for (int i = monitors.size() - 1; i >= 0; i--) {
        if (monitors[i].isVirtual) {
            return i;
        }
    }
    return -1;
}

// ─── VDD Settings File ────────────────────────────────────────────────────────

QVector<VirtualDisplayVDD::VddResolution> VirtualDisplayVDD::readVddSettings() const {
    QVector<VddResolution> displays;
    if (m_vddPath.isEmpty()) return displays;

    // Try each known settings file
    for (const auto& filename : kSettingsFiles) {
        QString path = m_vddPath + "/" + filename;
        QFile file(path);
        if (!file.exists() || !file.open(QIODevice::ReadOnly)) continue;

        QXmlStreamReader xml(&file);
        VddResolution current = {0, 0, 0};

        while (!xml.atEnd()) {
            xml.readNext();
            if (xml.isStartElement()) {
                QString name = xml.name().toString();
                if (name == "Width" || name == "width") {
                    current.width = xml.readElementText().toInt();
                } else if (name == "Height" || name == "height") {
                    current.height = xml.readElementText().toInt();
                } else if (name == "RefreshRate" || name == "refreshRate" ||
                           name == "Refresh" || name == "refresh") {
                    current.refreshRate = xml.readElementText().toInt();
                }
            } else if (xml.isEndElement()) {
                QString name = xml.name().toString();
                if ((name == "Display" || name == "display" || name == "Monitor" || name == "monitor")
                    && current.width > 0 && current.height > 0) {
                    if (current.refreshRate == 0) current.refreshRate = 60;
                    displays.append(current);
                    current = {0, 0, 0};
                }
            }
        }

        file.close();
        if (!displays.isEmpty()) break;
    }

    return displays;
}

bool VirtualDisplayVDD::writeVddSettings(const QVector<VddResolution>& displays) {
    if (m_vddPath.isEmpty()) return false;

    // Find existing settings file, or create the first known one
    QString settingsPath;
    for (const auto& filename : kSettingsFiles) {
        QString path = m_vddPath + "/" + filename;
        if (QFileInfo::exists(path)) {
            settingsPath = path;
            break;
        }
    }
    if (settingsPath.isEmpty()) {
        settingsPath = m_vddPath + "/" + kSettingsFiles.first();
    }

    QFile file(settingsPath);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        qWarning() << "VDD: Cannot write settings to" << settingsPath;
        return false;
    }

    QXmlStreamWriter xml(&file);
    xml.setAutoFormatting(true);
    xml.writeStartDocument();
    xml.writeStartElement("VirtualDisplaySettings");
    xml.writeStartElement("Displays");

    for (const auto& disp : displays) {
        xml.writeStartElement("Display");
        xml.writeTextElement("Width", QString::number(disp.width));
        xml.writeTextElement("Height", QString::number(disp.height));
        xml.writeTextElement("RefreshRate", QString::number(disp.refreshRate));
        xml.writeEndElement(); // Display
    }

    xml.writeEndElement(); // Displays
    xml.writeEndElement(); // VirtualDisplaySettings
    xml.writeEndDocument();

    file.close();
    qDebug() << "VDD: Wrote" << displays.size() << "display(s) to" << settingsPath;
    return true;
}

// ─── Driver Communication ──────────────────────────────────────────────────────

bool VirtualDisplayVDD::tryNamedPipe(const QString& command) {
#ifdef _WIN32
    HANDLE pipe = CreateFileA(
        kVddPipeName,
        GENERIC_READ | GENERIC_WRITE,
        0, nullptr,
        OPEN_EXISTING,
        0, nullptr);

    if (pipe == INVALID_HANDLE_VALUE) {
        qDebug() << "VDD: Named pipe not available, falling back to config file";
        return false;
    }

    QByteArray data = command.toUtf8();
    DWORD bytesWritten = 0;
    BOOL success = WriteFile(pipe, data.data(), data.size(), &bytesWritten, nullptr);

    if (success) {
        // Read response
        char buffer[1024] = {};
        DWORD bytesRead = 0;
        ReadFile(pipe, buffer, sizeof(buffer) - 1, &bytesRead, nullptr);
        if (bytesRead > 0) {
            QString response = QString::fromUtf8(buffer, bytesRead);
            qDebug() << "VDD pipe response:" << response;
        }
    }

    CloseHandle(pipe);
    return success && bytesWritten > 0;
#else
    Q_UNUSED(command);
    return false;
#endif
}

bool VirtualDisplayVDD::notifyDriverRefresh() {
#ifdef _WIN32
    // Method 1: Try named pipe with refresh command
    if (tryNamedPipe("{\"command\":\"refresh\"}")) {
        return true;
    }

    // Method 2: Use devcon to restart the driver device
    // This is heavier-handed but reliable
    QProcess proc;
    proc.setProgram("pnputil");
    proc.setArguments({"/restart-device", "Root\\VirtualDisplayDriver\\0000"});
    proc.start();
    if (proc.waitForFinished(10000) && proc.exitCode() == 0) {
        qDebug() << "VDD: Driver restarted via pnputil";
        return true;
    }

    // Method 3: Try devcon (if installed)
    proc.setProgram("devcon");
    proc.setArguments({"restart", "Root\\VirtualDisplayDriver"});
    proc.start();
    if (proc.waitForFinished(10000) && proc.exitCode() == 0) {
        qDebug() << "VDD: Driver restarted via devcon";
        return true;
    }

    qWarning() << "VDD: Could not notify driver — virtual display may require manual restart";
    return false;
#else
    return false;
#endif
}
