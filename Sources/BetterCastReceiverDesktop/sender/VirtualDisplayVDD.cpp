#include "VirtualDisplayVDD.h"
#include "../MainWindow.h"  // LogManager

#include <QDebug>
#include <QCoreApplication>
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

// Log to both qDebug and the in-app LogManager
#define VDD_LOG(msg) do { \
    QString _m = (msg); \
    qDebug().noquote() << _m; \
    LogManager::instance().log(_m); \
} while(0)

#ifdef _WIN32
#include <Windows.h>
#include <dxgi.h>
#include <SetupAPI.h>
#include <devguid.h>
#include <cfgmgr32.h>

#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "setupapi.lib")
#endif

// Known VDD installation paths (static fallbacks)
static const QStringList kVddPathsBase = {
    "C:/VirtualDisplayDriver",
    "C:/Program Files/Virtual Display Driver",
    "C:/Program Files/VirtualDisplayDriver",
    "C:/IddSampleDriver",
};

// Build full path list at runtime (QCoreApplication must exist)
static QStringList getVddPaths() {
    QStringList paths;
    // Check next to the app executable first (NSIS installs VDD here)
    QString appDir = QCoreApplication::applicationDirPath();
    if (!appDir.isEmpty()) {
        paths.append(appDir + "/VirtualDisplayDriver");
    }
    paths.append(kVddPathsBase);
    return paths;
}

// VDD settings file names (varies by version)
static const QStringList kSettingsFiles = {
    "vdd_settings.xml",
    "settings.xml",
    "config.xml",
    "option.txt",
    "options.xml",
};

// VDD named pipe (modern versions)
static const char* kVddPipeName = "\\\\.\\pipe\\VDDPipe";

// VDD hardware IDs to look for
static const QStringList kVddHardwareIds = {
    "Root\\VirtualDisplayDriver",
    "Root\\IddSampleDriver",
    "Root\\VDD",
    "VDD",
    "IddSampleDriver",
    "MttVDD",
};

VirtualDisplayVDD::VirtualDisplayVDD(QObject* parent)
    : QObject(parent)
{
    m_vddInstalled = detectVddInstall();
    if (m_vddInstalled) {
        VDD_LOG("VDD: Found installation at " + m_vddPath);
    } else {
        VDD_LOG("VDD: Not installed — checked registry, known paths, services, and devices");
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

void VirtualDisplayVDD::refreshInstallStatus() {
    bool wasInstalled = m_vddInstalled;
    m_vddPath.clear();
    m_vddInstalled = detectVddInstall();
    if (m_vddInstalled && !wasInstalled) {
        VDD_LOG("VDD: Now detected at " + m_vddPath);
        emit statusChanged("Virtual Display Driver detected");
    } else if (!m_vddInstalled) {
        VDD_LOG("VDD: Still not detected after refresh");
    }
}

bool VirtualDisplayVDD::detectVddInstall() {
    VDD_LOG("VDD: Starting detection...");

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
                VDD_LOG("VDD [Method 0]: Registry key found, path=" + path);
                if (QDir(path).exists()) {
                    m_vddPath = path;
                    VDD_LOG("VDD [Method 0]: Directory exists — detected via registry");
                    return true;
                } else {
                    VDD_LOG("VDD [Method 0]: Directory does NOT exist");
                }
            } else {
                VDD_LOG("VDD [Method 0]: Registry key exists but VDDPath value not found");
            }
        } else {
            VDD_LOG("VDD [Method 0]: No HKLM\\Software\\BetterCast registry key");
        }
    }
#endif

    // Method 1: Check known installation paths
    for (const auto& basePath : getVddPaths()) {
        QDir dir(basePath);
        if (dir.exists()) {
            VDD_LOG("VDD [Method 1]: Directory exists: " + basePath);
            // Verify there's actually a driver or settings file here
            for (const auto& settingsFile : kSettingsFiles) {
                if (QFileInfo::exists(basePath + "/" + settingsFile)) {
                    m_vddPath = basePath;
                    VDD_LOG("VDD [Method 1]: Found settings file " + settingsFile + " in " + basePath);
                    return true;
                }
            }
            // Check for driver files even without settings
            if (QFileInfo::exists(basePath + "/VirtualDisplayDriver.dll") ||
                QFileInfo::exists(basePath + "/IddSampleDriver.dll") ||
                QFileInfo::exists(basePath + "/MttVDD.dll")) {
                m_vddPath = basePath;
                VDD_LOG("VDD [Method 1]: Found driver DLL in " + basePath);
                return true;
            }
            // Check for driver .inf files
            if (QFileInfo::exists(basePath + "/VirtualDisplayDriver.inf") ||
                QFileInfo::exists(basePath + "/MttVDD.inf")) {
                m_vddPath = basePath;
                VDD_LOG("VDD [Method 1]: Found driver .inf in " + basePath);
                return true;
            }
            // Check for VDD Control exe (newer versions — filename may use space or dot)
            if (QFileInfo::exists(basePath + "/VDD Control.exe") ||
                QFileInfo::exists(basePath + "/VDD.Control.exe")) {
                m_vddPath = basePath;
                VDD_LOG("VDD [Method 1]: Found VDD.Control.exe in " + basePath);
                return true;
            }
            // List what IS in the directory for debugging
            QStringList files = dir.entryList(QDir::Files);
            VDD_LOG("VDD [Method 1]: Files in " + basePath + ": " +
                    (files.isEmpty() ? "(empty)" : files.join(", ")));
        }
    }
    VDD_LOG("VDD [Method 1]: No known paths matched");

#ifdef _WIN32
    // Method 2: Check registry for VDD driver service
    static const wchar_t* serviceKeys[] = {
        L"SYSTEM\\CurrentControlSet\\Services\\VirtualDisplayDriver",
        L"SYSTEM\\CurrentControlSet\\Services\\IddSampleDriver",
        L"SYSTEM\\CurrentControlSet\\Services\\MttVDD",
    };
    for (const auto* svcKey : serviceKeys) {
        HKEY hKey;
        LONG result = RegOpenKeyExW(HKEY_LOCAL_MACHINE, svcKey, 0, KEY_READ, &hKey);
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
                VDD_LOG("VDD [Method 2]: Found service at " + QString::fromWCharArray(svcKey) +
                        ", imagePath=" + path);
                return true;
            } else {
                VDD_LOG("VDD [Method 2]: Service key " + QString::fromWCharArray(svcKey) +
                        " exists but no ImagePath");
            }
        }
    }
    VDD_LOG("VDD [Method 2]: No VDD service found in registry");

    // Method 3: Check for VDD device via SetupDI
    HDEVINFO devInfo = SetupDiGetClassDevsW(
        &GUID_DEVCLASS_DISPLAY, nullptr, nullptr,
        DIGCF_PRESENT | DIGCF_ALLCLASSES);
    if (devInfo != INVALID_HANDLE_VALUE) {
        SP_DEVINFO_DATA devData = {};
        devData.cbSize = sizeof(devData);
        int deviceCount = 0;
        for (DWORD i = 0; SetupDiEnumDeviceInfo(devInfo, i, &devData); i++) {
            wchar_t hwId[512] = {};
            if (SetupDiGetDeviceRegistryPropertyW(devInfo, &devData,
                    SPDRP_HARDWAREID, nullptr,
                    reinterpret_cast<PBYTE>(hwId), sizeof(hwId), nullptr)) {
                QString id = QString::fromWCharArray(hwId).toLower();
                deviceCount++;
                for (const auto& vddId : kVddHardwareIds) {
                    if (id.contains(vddId.toLower())) {
                        SetupDiDestroyDeviceInfoList(devInfo);
                        if (m_vddPath.isEmpty()) {
                            for (const auto& p : getVddPaths()) {
                                if (QDir(p).exists()) { m_vddPath = p; break; }
                            }
                        }
                        VDD_LOG("VDD [Method 3]: Found device with hwId=" + id);
                        return true;
                    }
                }
            }
        }
        SetupDiDestroyDeviceInfoList(devInfo);
        VDD_LOG(QString("VDD [Method 3]: Scanned %1 display devices, none matched VDD hardware IDs").arg(deviceCount));
    } else {
        VDD_LOG("VDD [Method 3]: SetupDiGetClassDevs failed");
    }
#endif

    return false;
}

bool VirtualDisplayVDD::isDriverLoaded() const {
#ifdef _WIN32
    // Check if any VDD service is registered
    static const wchar_t* serviceKeys[] = {
        L"SYSTEM\\CurrentControlSet\\Services\\MttVDD",
        L"SYSTEM\\CurrentControlSet\\Services\\VirtualDisplayDriver",
        L"SYSTEM\\CurrentControlSet\\Services\\IddSampleDriver",
    };
    for (const auto* svcKey : serviceKeys) {
        HKEY hKey;
        if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, svcKey, 0, KEY_READ, &hKey) == ERROR_SUCCESS) {
            RegCloseKey(hKey);
            return true;
        }
    }

    // Also check via named pipe — if pipe exists, driver is running
    HANDLE pipe = CreateFileA(kVddPipeName, GENERIC_READ | GENERIC_WRITE,
                              0, nullptr, OPEN_EXISTING, 0, nullptr);
    if (pipe != INVALID_HANDLE_VALUE) {
        CloseHandle(pipe);
        return true;
    }
#endif
    return false;
}

bool VirtualDisplayVDD::installDriver() {
#ifdef _WIN32
    if (m_vddPath.isEmpty()) return false;

    // Try installing each .inf file found in the VDD directory
    QDir vddDir(m_vddPath);
    QStringList infFiles = vddDir.entryList({"*.inf"}, QDir::Files);

    if (infFiles.isEmpty()) {
        VDD_LOG("VDD: No .inf files found in " + m_vddPath);
        return false;
    }

    for (const auto& inf : infFiles) {
        QString infPath = m_vddPath + "/" + inf;
        VDD_LOG("VDD: Attempting pnputil /add-driver \"" + infPath + "\" /install");

        QProcess proc;
        proc.setProgram("pnputil");
        proc.setArguments({"/add-driver", infPath, "/install"});
        proc.start();
        if (proc.waitForFinished(30000)) {
            QString output = proc.readAllStandardOutput() + proc.readAllStandardError();
            VDD_LOG("VDD: pnputil output: " + output.trimmed());
            if (proc.exitCode() == 0) {
                VDD_LOG("VDD: Driver installed via " + inf);
                // Give Windows time to register the device
                QThread::msleep(2000);
                return true;
            }
        }
    }

    // Try launching VDD Control to install
    QString controlExe = m_vddPath + "/VDD Control.exe";
    if (!QFileInfo::exists(controlExe)) {
        controlExe = m_vddPath + "/VDD.Control.exe";
    }
    if (QFileInfo::exists(controlExe)) {
        VDD_LOG("VDD: Launching VDD Control for driver installation: " + controlExe);
        QProcess::startDetached(controlExe, {});
        emit error("VDD Control launched — use it to install the driver, then try again");
        return false;
    }

    VDD_LOG("VDD: All driver install methods failed");
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

    // First check if the driver is actually loaded in Windows
    // (files on disk ≠ driver installed)
    if (!isDriverLoaded()) {
        VDD_LOG("VDD: Driver files found but driver not loaded in Windows — attempting install...");
        if (!installDriver()) {
            emit error("VDD driver files exist but the driver isn't installed in Windows. "
                       "Try running 'VDD Control.exe' from the VirtualDisplayDriver folder, "
                       "or run as admin: pnputil /add-driver MttVDD.inf /install");
            return false;
        }
        VDD_LOG("VDD: Driver installed successfully");
    }

    // Method 1: Try VDD named pipe (modern versions)
    VDD_LOG("VDD: Trying named pipe to create display...");
    QString pipeCmd = QString("{\"command\":\"add\",\"width\":%1,\"height\":%2,\"refreshRate\":%3}")
                          .arg(width).arg(height).arg(refreshRate);
    if (tryNamedPipe(pipeCmd)) {
        VDD_LOG("VDD: Named pipe succeeded");
        m_createdDisplayCount++;
        emit statusChanged(QString("Virtual display created: %1x%2 @ %3Hz")
                               .arg(width).arg(height).arg(refreshRate));
        QThread::msleep(1500);
        int outputIdx = findVirtualDisplayOutput();
        if (outputIdx < 0) {
            VDD_LOG("VDD: Warning — pipe reported success but virtual display not found in monitor list");
        }
        emit virtualDisplayCreated(outputIdx);
        return true;
    }

    // Method 2: Modify settings file + notify driver
    VDD_LOG("VDD: Named pipe unavailable, trying settings file method...");
    auto displays = readVddSettings();
    displays.append({width, height, refreshRate});

    if (!writeVddSettings(displays)) {
        emit error("Failed to write VDD settings file");
        return false;
    }
    VDD_LOG("VDD: Settings file written, notifying driver...");

    if (!notifyDriverRefresh()) {
        emit error("Failed to notify VDD driver — try restarting the driver manually");
        return false;
    }

    m_createdDisplayCount++;
    emit statusChanged(QString("Virtual display created: %1x%2 @ %3Hz")
                           .arg(width).arg(height).arg(refreshRate));

    QThread::msleep(2000);
    int outputIdx = findVirtualDisplayOutput();
    if (outputIdx < 0) {
        VDD_LOG("VDD: Warning — settings written but virtual display not found in monitor list");
    }
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
    VDD_LOG(QString("VDD: Wrote %1 display(s) to %2").arg(displays.size()).arg(settingsPath));
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
        VDD_LOG("VDD: Named pipe not available (error " + QString::number(GetLastError()) + ")");
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
            VDD_LOG("VDD: Pipe response: " + response);
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

    // Method 2: Try pnputil restart with various device IDs
    static const char* deviceIds[] = {
        "Root\\MttVDD\\0000",
        "Root\\VirtualDisplayDriver\\0000",
        "Root\\IddSampleDriver\\0000",
    };
    for (const auto* devId : deviceIds) {
        QProcess proc;
        proc.setProgram("pnputil");
        proc.setArguments({"/restart-device", devId});
        proc.start();
        if (proc.waitForFinished(10000) && proc.exitCode() == 0) {
            VDD_LOG(QString("VDD: Driver restarted via pnputil (%1)").arg(devId));
            return true;
        }
    }

    // Method 3: Try devcon (bundled in VDD directory or system PATH)
    QString devconPath = m_vddPath + "/devcon.exe";
    if (!QFileInfo::exists(devconPath)) devconPath = "devcon";

    static const char* hwIds[] = {"Root\\MttVDD", "Root\\VirtualDisplayDriver"};
    for (const auto* hwId : hwIds) {
        QProcess proc;
        proc.setProgram(devconPath);
        proc.setArguments({"restart", hwId});
        proc.start();
        if (proc.waitForFinished(10000) && proc.exitCode() == 0) {
            VDD_LOG(QString("VDD: Driver restarted via devcon (%1)").arg(hwId));
            return true;
        }
    }

    VDD_LOG("VDD: Could not notify driver — all restart methods failed");
    return false;
#else
    return false;
#endif
}
