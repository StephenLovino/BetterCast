#include "VirtualDisplayVDD.h"
#include "../LogManager.h"

#include <QDebug>
#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QProcess>
#include <QSet>
#include <QThread>
#include <QElapsedTimer>
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
#include <shellapi.h>   // ShellExecuteEx, for the elevated removal helper
#include <cstring>      // memcpy, for the saved primary DEVMODE
#include <string>

#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "setupapi.lib")
#pragma comment(lib, "user32.lib")   // CCD: QueryDisplayConfig / SetDisplayConfig
#pragma comment(lib, "shell32.lib")  // ShellExecuteEx

#ifndef DISPLAYCONFIG_PATH_MODE_IDX_INVALID
#define DISPLAYCONFIG_PATH_MODE_IDX_INVALID 0xffffffff
#endif
#endif

// ─── CCD (Connecting and Configuring Displays) helpers ────────────────────────
#ifdef _WIN32
namespace {

// Keywords shared with the DXGI/GDI enumeration paths below.
bool looksVirtual(const QString& text) {
    static const QStringList kKeys = {"virtual", "indirect", "idd", "vdd", "mtt"};
    QString lower = text.toLower();
    for (const auto& k : kKeys) {
        if (lower.contains(k)) return true;
    }
    return false;
}

bool isVirtualTarget(const DISPLAYCONFIG_PATH_INFO& path) {
    DISPLAYCONFIG_TARGET_DEVICE_NAME name = {};
    name.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME;
    name.header.size = sizeof(name);
    name.header.adapterId = path.targetInfo.adapterId;
    name.header.id = path.targetInfo.id;
    if (DisplayConfigGetDeviceInfo(&name.header) != ERROR_SUCCESS) return false;

    if (looksVirtual(QString::fromWCharArray(name.monitorFriendlyDeviceName)) ||
        looksVirtual(QString::fromWCharArray(name.monitorDevicePath))) {
        return true;
    }
    // IddCx targets have no real connector, so they report OTHER.
    return name.outputTechnology == DISPLAYCONFIG_OUTPUT_TECHNOLOGY_OTHER;
}

// GetDisplayConfigBufferSizes → QueryDisplayConfig, retrying the race where a
// display is hotplugged between the two calls.
bool queryPaths(QVector<DISPLAYCONFIG_PATH_INFO>& paths,
                QVector<DISPLAYCONFIG_MODE_INFO>& modes,
                UINT32 flags) {
    for (int attempt = 0; attempt < 5; attempt++) {
        UINT32 pathCount = 0, modeCount = 0;
        if (GetDisplayConfigBufferSizes(flags, &pathCount, &modeCount) != ERROR_SUCCESS) {
            return false;
        }
        if (pathCount == 0 || modeCount == 0) return false;  // no displays to reason about
        paths.resize(static_cast<int>(pathCount));
        modes.resize(static_cast<int>(modeCount));

        LONG r = QueryDisplayConfig(flags, &pathCount, paths.data(),
                                    &modeCount, modes.data(), nullptr);
        if (r == ERROR_SUCCESS) {
            paths.resize(static_cast<int>(pathCount));
            modes.resize(static_cast<int>(modeCount));
            return true;
        }
        if (r != ERROR_INSUFFICIENT_BUFFER) return false;  // only the race is retryable
    }
    return false;
}

// What Windows calls the display adapter and monitor behind "\\.\DISPLAYn".
//
// DXGI_ADAPTER_DESC1.Description is the *rendering* adapter, and an indirect
// display renders on a real GPU — so a VDD monitor reports "NVIDIA GeForce ..."
// or "Intel(R) UHD Graphics" there and is indistinguishable from a physical one.
// EnumDisplayDevices reports the display adapter instead, which is the VDD.
// Observed: DISPLAY21/24/25 were labelled NVIDIA/Intel and lost their [Virtual]
// tag as soon as they attached, while the log had already identified all four as
// "Virtual Display Driver".
// The DISPLAY ADAPTER behind "\\.\DISPLAYn" — "Virtual Display Driver" for a
// VDD monitor, "Intel(R) UHD Graphics" for a real one.
//
// Deliberately only the adapter string. An earlier version also folded in the
// monitor name and its DeviceID and substring-matched the lot, which was noisy
// enough to match the built-in laptop panel: every display on the machine came
// back tagged [Virtual], including DISPLAY1.
QString displayAdapterString(const QString& deviceName) {
    DISPLAY_DEVICEW dd = {};
    dd.cb = sizeof(dd);
    for (DWORD i = 0; EnumDisplayDevicesW(nullptr, i, &dd, 0); i++) {
        if (deviceName.compare(QString::fromWCharArray(dd.DeviceName),
                               Qt::CaseInsensitive) == 0) {
            return QString::fromWCharArray(dd.DeviceString);
        }
        dd = {};
        dd.cb = sizeof(dd);
    }
    return QString();
}

// ChangeDisplaySettingsEx returns bare negative numbers; naming them turns an
// unhelpful "code -1" log line into something diagnosable.
QString dispChangeName(LONG code) {
    switch (code) {
        case  0: return "SUCCESSFUL";
        case  1: return "RESTART required";
        case -1: return "FAILED";
        case -2: return "BADMODE";
        case -3: return "NOTUPDATED";
        case -4: return "BADFLAGS";
        case -5: return "BADPARAM";
        case -6: return "BADDUALVIEW";
        default: return QString::number(code);
    }
}

QString sourceKey(const DISPLAYCONFIG_PATH_INFO& p) {
    return QString("%1:%2:%3").arg(p.sourceInfo.adapterId.HighPart)
                              .arg(p.sourceInfo.adapterId.LowPart)
                              .arg(p.sourceInfo.id);
}

QString targetKey(const DISPLAYCONFIG_PATH_INFO& p) {
    return QString("%1:%2:%3").arg(p.targetInfo.adapterId.HighPart)
                              .arg(p.targetInfo.adapterId.LowPart)
                              .arg(p.targetInfo.id);
}

} // namespace
#endif

// Known VDD installation paths (static fallbacks)
static const QStringList kVddPathsBase = {
    // Where BetterCast's own installer puts it. Only the app directory was
    // checked before, which works when the app is the installed one and fails
    // for anything else running on the same machine - a build in Downloads
    // found no path at all, so the settings write failed and every virtual
    // display stayed at the driver's 800x600.
    "C:/Program Files/BetterCast/VirtualDisplayDriver",
    "C:/Program Files (x86)/BetterCast/VirtualDisplayDriver",
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
    // Match the real screen by default. The driver's own default is 800x600,
    // which is what second displays were streaming at.
    const QSize primary = primaryResolution();
    m_preferredWidth = primary.width();
    m_preferredHeight = primary.height();

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

    // Last, and the only direct evidence: does a virtual display actually exist?
    //
    // Both checks above are proxies and both can be false while the driver is plainly
    // working. The service key depends on the name the INF happens to register, which
    // has changed across VDD releases, and the pipe only exists while VDD Control.exe
    // is running — which it usually is not. Reported logs show a monitor enumerated as
    // "Virtual Display Driver" on DISPLAY8 and, on the very next line, "driver not
    // loaded in Windows", followed by a doomed unelevated install attempt. Asking
    // Windows what displays are present settles it without guessing at names.
    for (const auto& mon : enumerateMonitors()) {
        if (mon.isVirtual) {
            return true;
        }
    }
#endif
    return false;
}

bool VirtualDisplayVDD::installDriver() {
#ifdef _WIN32
    if (m_vddPath.isEmpty()) return false;

    // Find devcon.exe (bundled in VDD directory or Dependencies subfolder)
    QString devconExe = m_vddPath + "/devcon.exe";
    if (!QFileInfo::exists(devconExe)) {
        devconExe = m_vddPath + "/Dependencies/devcon.exe";
    }

    // Find the MttVDD .inf file
    QString infPath;
    if (QFileInfo::exists(m_vddPath + "/MttVDD.inf")) {
        infPath = m_vddPath + "/MttVDD.inf";
    } else {
        // Fall back to first .inf found
        QDir vddDir(m_vddPath);
        QStringList infFiles = vddDir.entryList({"*.inf"}, QDir::Files);
        if (!infFiles.isEmpty()) {
            infPath = m_vddPath + "/" + infFiles.first();
        }
    }

    if (infPath.isEmpty()) {
        VDD_LOG("VDD: No .inf files found in " + m_vddPath);
        return false;
    }

    // Method 1: devcon install — creates device node + installs driver (preferred for IDD)
    if (QFileInfo::exists(devconExe)) {
        VDD_LOG("VDD: Installing via devcon: " + devconExe + " install " + infPath + " Root\\MttVDD");
        QProcess proc;
        proc.setProgram(devconExe);
        proc.setArguments({"install", infPath, "Root\\MttVDD"});
        proc.start();
        if (proc.waitForFinished(30000)) {
            QString output = proc.readAllStandardOutput() + proc.readAllStandardError();
            VDD_LOG("VDD: devcon output: " + output.trimmed());
            if (proc.exitCode() == 0) {
                VDD_LOG("VDD: Driver device created via devcon");
                QThread::msleep(2000);
                return true;
            }
        }
    } else {
        VDD_LOG("VDD: devcon.exe not found, trying pnputil...");
    }

    // Method 2: pnputil — adds driver to store (may not create device node for IDD)
    VDD_LOG("VDD: Attempting pnputil /add-driver \"" + infPath + "\" /install");
    QProcess proc;
    proc.setProgram("pnputil");
    proc.setArguments({"/add-driver", infPath, "/install"});
    proc.start();
    if (proc.waitForFinished(30000)) {
        QString output = proc.readAllStandardOutput() + proc.readAllStandardError();
        VDD_LOG("VDD: pnputil output: " + output.trimmed());
        if (proc.exitCode() == 0) {
            VDD_LOG("VDD: Driver added to store via pnputil");
        }
    }

    // After pnputil, try creating the device node explicitly
    if (QFileInfo::exists(devconExe)) {
        VDD_LOG("VDD: Creating device node via devcon...");
        QProcess devProc;
        devProc.setProgram(devconExe);
        devProc.setArguments({"install", infPath, "Root\\MttVDD"});
        devProc.start();
        if (devProc.waitForFinished(30000) && devProc.exitCode() == 0) {
            VDD_LOG("VDD: Device node created");
            QThread::msleep(2000);
            return true;
        }
    }

    VDD_LOG("VDD: All driver install methods failed — devcon.exe may be required");
#endif
    return false;
}

// ─── Virtual Display Management ────────────────────────────────────────────────

bool VirtualDisplayVDD::ensureVddControlRunning() {
#ifdef _WIN32
    // Check if pipe already exists (VDD Control is running)
    HANDLE pipe = CreateFileA(kVddPipeName, GENERIC_READ | GENERIC_WRITE,
                              0, nullptr, OPEN_EXISTING, 0, nullptr);
    if (pipe != INVALID_HANDLE_VALUE) {
        CloseHandle(pipe);
        VDD_LOG("VDD: VDD Control is already running (pipe available)");
        return true;
    }

    // Try to launch VDD Control
    QString controlExe = m_vddPath + "/VDD Control.exe";
    if (!QFileInfo::exists(controlExe)) {
        controlExe = m_vddPath + "/VDD.Control.exe";
    }
    if (!QFileInfo::exists(controlExe)) {
        VDD_LOG("VDD: VDD Control.exe not found in " + m_vddPath);
        return false;
    }

    VDD_LOG("VDD: Starting VDD Control: " + controlExe);
    QProcess::startDetached(controlExe, {});

    // Wait for the pipe to become available (VDD Control needs startup time)
    for (int i = 0; i < 20; i++) {  // Up to 10 seconds
        QThread::msleep(500);
        pipe = CreateFileA(kVddPipeName, GENERIC_READ | GENERIC_WRITE,
                           0, nullptr, OPEN_EXISTING, 0, nullptr);
        if (pipe != INVALID_HANDLE_VALUE) {
            CloseHandle(pipe);
            VDD_LOG("VDD: VDD Control started, pipe available");
            return true;
        }
    }
    VDD_LOG("VDD: VDD Control started but pipe not available after 10s");
    return false;
#else
    return false;
#endif
}

bool VirtualDisplayVDD::activateVirtualDisplay() {
#ifdef _WIN32
    // Find an inactive/disconnected virtual display and extend the desktop to it
    DISPLAY_DEVICEW dd = {};
    dd.cb = sizeof(dd);
    for (DWORD i = 0; EnumDisplayDevicesW(nullptr, i, &dd, 0); i++) {
        QString devString = QString::fromWCharArray(dd.DeviceString).toLower();
        bool isVirtual = devString.contains("virtual") || devString.contains("indirect") ||
                         devString.contains("idd") || devString.contains("vdd") ||
                         devString.contains("mtt");

        if (isVirtual && !(dd.StateFlags & DISPLAY_DEVICE_ATTACHED_TO_DESKTOP)) {
            QString devName = QString::fromWCharArray(dd.DeviceName);
            VDD_LOG("VDD: Found disconnected virtual display: " + devName + " (" +
                    QString::fromWCharArray(dd.DeviceString) + ") — activating...");

            // Get the primary monitor's position to place virtual display to the right
            DEVMODEW primaryDm = {};
            primaryDm.dmSize = sizeof(primaryDm);
            EnumDisplaySettingsW(nullptr, ENUM_CURRENT_SETTINGS, &primaryDm);

            DEVMODEW dm = {};
            dm.dmSize = sizeof(dm);
            dm.dmFields = DM_POSITION | DM_PELSWIDTH | DM_PELSHEIGHT;
            dm.dmPosition.x = static_cast<LONG>(primaryDm.dmPelsWidth);  // Place to the right
            dm.dmPosition.y = 0;

            // Try to get the intended resolution from settings
            if (EnumDisplaySettingsW(dd.DeviceName, ENUM_REGISTRY_SETTINGS, &dm)) {
                dm.dmFields = DM_POSITION | DM_PELSWIDTH | DM_PELSHEIGHT;
                dm.dmPosition.x = static_cast<LONG>(primaryDm.dmPelsWidth);
                dm.dmPosition.y = 0;
            } else {
                dm.dmPelsWidth = 1920;
                dm.dmPelsHeight = 1080;
            }

            LONG ret = ChangeDisplaySettingsExW(
                dd.DeviceName, &dm, nullptr,
                CDS_UPDATEREGISTRY | CDS_NORESET, nullptr);

            if (ret == DISP_CHANGE_SUCCESSFUL) {
                // Apply changes globally
                ChangeDisplaySettingsExW(nullptr, nullptr, nullptr, 0, nullptr);
                VDD_LOG(QString("VDD: Virtual display activated at position %1,0 (%2x%3)")
                            .arg(dm.dmPosition.x).arg(dm.dmPelsWidth).arg(dm.dmPelsHeight));
                QThread::msleep(1000);
                return true;
            } else {
                VDD_LOG(QString("VDD: ChangeDisplaySettingsEx failed with code %1").arg(ret));
            }
        }
        dd = {};
        dd.cb = sizeof(dd);
    }
    VDD_LOG("VDD: No disconnected virtual display found to activate");
#endif
    return false;
}

QSize VirtualDisplayVDD::primaryResolution() {
#ifdef _WIN32
    DEVMODEW dm = {};
    dm.dmSize = sizeof(dm);
    if (EnumDisplaySettingsW(nullptr, ENUM_CURRENT_SETTINGS, &dm) &&
        dm.dmPelsWidth > 0 && dm.dmPelsHeight > 0) {
        return QSize(static_cast<int>(dm.dmPelsWidth), static_cast<int>(dm.dmPelsHeight));
    }
#endif
    return QSize(1920, 1080);
}

bool VirtualDisplayVDD::ensureResolutionAdvertised(int width, int height) {
    if (!m_vddInstalled || width <= 0 || height <= 0) return false;

    auto displays = readVddSettings();
    for (const auto& d : displays) {
        if (d.width == width && d.height == height) {
            return true;   // already offered — nothing to do, no driver restart
        }
    }

    VDD_LOG(QString("VDD: %1x%2 is not in vdd_settings.xml — adding it so virtual "
                    "displays can actually run at that size")
                .arg(width).arg(height));

    // Keep whatever else is listed; we are adding a mode, not replacing the set.
    displays.append({width, height, 60});
    if (!writeVddSettings(displays)) {
        // Log as well as signal. This runs during construction, before anything
        // has connected to error(), so the signal alone went nowhere and the
        // failure looked like silence in the log.
        VDD_LOG("VDD: Could not update the Virtual Display Driver settings file — "
                "virtual displays will stay at the driver's default size");
        emit error("Could not update the Virtual Display Driver settings file. "
                   "BetterCast may need to run as administrator once.");
        return false;
    }

    // Confirm the mode is really listed now. The write reporting success is not
    // the same as the driver offering the size.
    bool advertised = false;
    for (const auto& d : readVddSettings()) {
        if (d.width == width && d.height == height) { advertised = true; break; }
    }
    if (!advertised) {
        VDD_LOG(QString("VDD: %1x%2 is still missing from vdd_settings.xml after "
                        "writing it").arg(width).arg(height));
        return false;
    }

    notifyDriverRefresh();
    QThread::msleep(1500);
    VDD_LOG(QString("VDD: Driver refreshed — %1x%2 is now on offer")
                .arg(width).arg(height));
    return true;
}

QVector<QSize> VirtualDisplayVDD::commonResolutions() {
    // Enough to cover phones, tablets and laptops without turning the picker
    // into a wall of numbers. The primary's own size is added on top by
    // ensureResolutionsAdvertised, so a matching option is always present.
    return {
        QSize(3840, 2160),
        QSize(2560, 1440),
        QSize(1920, 1200),
        QSize(1920, 1080),
        QSize(1680, 1050),
        QSize(1600, 900),
        QSize(1440, 900),
        QSize(1366, 768),
        QSize(1280, 800),
        QSize(1280, 720),
        QSize(1024, 768),
    };
}

bool VirtualDisplayVDD::ensureResolutionsAdvertised(const QVector<QSize>& modes) {
    if (!m_vddInstalled) return false;

    auto existing = readVddSettings();
    auto alreadyListed = [&existing](const QSize& size) {
        for (const auto& d : existing) {
            if (d.width == size.width() && d.height == size.height()) return true;
        }
        return false;
    };

    QVector<QSize> missing;
    for (const auto& size : modes) {
        if (size.width() <= 0 || size.height() <= 0) continue;
        if (alreadyListed(size)) continue;
        // Guard against duplicates inside the requested set too.
        bool dupe = false;
        for (const auto& m : missing) {
            if (m == size) { dupe = true; break; }
        }
        if (!dupe) missing.append(size);
    }

    if (missing.isEmpty()) return true;   // nothing to do, no driver restart

    VDD_LOG(QString("VDD: Adding %1 display mode(s) to vdd_settings.xml so virtual "
                    "displays can run at any of them without another restart")
                .arg(missing.size()));

    for (const auto& size : missing) {
        existing.append({size.width(), size.height(), 60});
    }

    if (!writeVddSettings(existing)) {
        VDD_LOG("VDD: Could not update the Virtual Display Driver settings file — "
                "virtual displays will stay at the driver's default size");
        emit error("Could not update the Virtual Display Driver settings file. "
                   "BetterCast may need to run as administrator once.");
        return false;
    }

    notifyDriverRefresh();
    QThread::msleep(1500);
    VDD_LOG(QString("VDD: Driver refreshed — %1 mode(s) now on offer")
                .arg(existing.size()));
    return true;
}

bool VirtualDisplayVDD::attachVirtualDisplay(const QString& deviceName,
                                             int width, int height, int refreshRate) {
#ifdef _WIN32
    if (deviceName.isEmpty()) return false;
    // 0 means "match the primary", which is what a virtual display should do
    // rather than falling back to the driver's 800x600.
    if (width <= 0)  width = m_preferredWidth;
    if (height <= 0) height = m_preferredHeight;
    const std::wstring wname = deviceName.toStdWString();

    DISPLAY_DEVICEW dd = {};
    dd.cb = sizeof(dd);
    bool found = false;
    for (DWORD i = 0; EnumDisplayDevicesW(nullptr, i, &dd, 0); i++) {
        if (deviceName.compare(QString::fromWCharArray(dd.DeviceName), Qt::CaseInsensitive) == 0) {
            found = true;
            break;
        }
        dd = {};
        dd.cb = sizeof(dd);
    }
    if (!found) {
        VDD_LOG("VDD: " + deviceName + " not found, cannot attach");
        return false;
    }
    if (dd.StateFlags & DISPLAY_DEVICE_ATTACHED_TO_DESKTOP) {
        return true;   // already live
    }

    // Park it past everything currently on the desktop so it extends rather
    // than lands on top of another display.
    LONG rightEdge = 0;
    DISPLAY_DEVICEW scan = {};
    scan.cb = sizeof(scan);
    for (DWORD i = 0; EnumDisplayDevicesW(nullptr, i, &scan, 0); i++) {
        if (scan.StateFlags & DISPLAY_DEVICE_ATTACHED_TO_DESKTOP) {
            DEVMODEW m = {};
            m.dmSize = sizeof(m);
            if (EnumDisplaySettingsW(scan.DeviceName, ENUM_CURRENT_SETTINGS, &m)) {
                rightEdge = qMax(rightEdge, m.dmPosition.x + static_cast<LONG>(m.dmPelsWidth));
            }
        }
        scan = {};
        scan.cb = sizeof(scan);
    }

    // Use a mode the driver actually advertises rather than assembling one.
    //
    // The previous version started from ENUM_REGISTRY_SETTINGS, forced 32bpp and
    // a 60Hz refresh, and was refused with DISP_CHANGE_FAILED for every display
    // on a real machine — which is what stopped a second receiver ever getting a
    // screen. EnumDisplaySettings lists exactly what will be accepted, so pick
    // from there: the requested size if offered, otherwise the largest on offer.
    DEVMODEW chosen = {};
    bool haveMode = false;
    DEVMODEW probe = {};
    probe.dmSize = sizeof(probe);
    for (DWORD i = 0; EnumDisplaySettingsW(wname.c_str(), i, &probe); i++) {
        if (probe.dmBitsPerPel != 32) { probe = {}; probe.dmSize = sizeof(probe); continue; }

        const bool wantedSize = static_cast<int>(probe.dmPelsWidth) == width &&
                                static_cast<int>(probe.dmPelsHeight) == height;
        const bool chosenIsWanted = haveMode &&
                                    static_cast<int>(chosen.dmPelsWidth) == width &&
                                    static_cast<int>(chosen.dmPelsHeight) == height;

        bool better = false;
        if (!haveMode) {
            better = true;
        } else if (wantedSize && !chosenIsWanted) {
            better = true;                                  // exact size wins
        } else if (wantedSize == chosenIsWanted) {
            const quint64 a = quint64(probe.dmPelsWidth) * probe.dmPelsHeight;
            const quint64 b = quint64(chosen.dmPelsWidth) * chosen.dmPelsHeight;
            better = (a > b) || (a == b && probe.dmDisplayFrequency > chosen.dmDisplayFrequency);
        }
        if (better) { chosen = probe; haveMode = true; }

        probe = {};
        probe.dmSize = sizeof(probe);
    }

    if (!haveMode) {
        VDD_LOG("VDD: " + deviceName + " advertises no usable mode — cannot attach");
        return false;
    }

    DEVMODEW dm = chosen;
    dm.dmSize = sizeof(dm);
    dm.dmPosition.x = rightEdge;
    dm.dmPosition.y = 0;
    dm.dmFields = DM_POSITION | DM_PELSWIDTH | DM_PELSHEIGHT |
                  DM_BITSPERPEL | DM_DISPLAYFREQUENCY;

    // Retry over a few seconds rather than giving up on the first refusal. A
    // monitor that has only just been published answers DISP_CHANGE_FAILED to
    // everything for a while, and a one-shot attempt right after a node install
    // is exactly what left later receivers with no screen.
    LONG ret = DISP_CHANGE_FAILED;
    for (int attempt = 0; attempt < 4; attempt++) {
        if (attempt > 0) QThread::msleep(1000);

        dm.dmFields = DM_POSITION | DM_PELSWIDTH | DM_PELSHEIGHT |
                      DM_BITSPERPEL | DM_DISPLAYFREQUENCY;
        ret = ChangeDisplaySettingsExW(wname.c_str(), &dm, nullptr,
                                       CDS_UPDATEREGISTRY | CDS_NORESET, nullptr);
        if (ret == DISP_CHANGE_SUCCESSFUL) break;

        // Some IDD drivers refuse an explicit refresh rate; retry without it.
        dm.dmFields = DM_POSITION | DM_PELSWIDTH | DM_PELSHEIGHT;
        ret = ChangeDisplaySettingsExW(wname.c_str(), &dm, nullptr,
                                       CDS_UPDATEREGISTRY | CDS_NORESET, nullptr);
        if (ret == DISP_CHANGE_SUCCESSFUL) break;
    }
    if (ret != DISP_CHANGE_SUCCESSFUL) {
        VDD_LOG(QString("VDD: Could not attach %1 at %2x%3 — %4")
                    .arg(deviceName).arg(dm.dmPelsWidth).arg(dm.dmPelsHeight)
                    .arg(dispChangeName(ret)));
        return false;
    }
    VDD_LOG(QString("VDD: Attaching %1 using advertised mode %2x%3 @ %4Hz")
                .arg(deviceName).arg(dm.dmPelsWidth).arg(dm.dmPelsHeight)
                .arg(chosen.dmDisplayFrequency));

    LONG commit = ChangeDisplaySettingsExW(nullptr, nullptr, nullptr, 0, nullptr);
    if (commit != DISP_CHANGE_SUCCESSFUL) {
        VDD_LOG("VDD: Attach commit returned " + dispChangeName(commit));
        return false;
    }

    VDD_LOG(QString("VDD: Attached %1 at %2,0 (%3x%4)")
                .arg(deviceName).arg(rightEdge)
                .arg(dm.dmPelsWidth).arg(dm.dmPelsHeight));
    QThread::msleep(700);   // let the desktop settle before anything captures it
    return true;
#else
    Q_UNUSED(deviceName); Q_UNUSED(width); Q_UNUSED(height); Q_UNUSED(refreshRate);
    return false;
#endif
}

// ─── Display Topology (extend vs. mirror) ──────────────────────────────────────

QString VirtualDisplayVDD::TopologyState::describe() const {
    if (!valid) return QStringLiteral("unknown (query failed)");

    QString s = QString::number(activePaths) + " active path(s), ";
    s += anyCloned ? "MIRRORED" : "extended";
    if (!virtualActive)      s += ", no virtual display attached";
    else if (virtualCloned)  s += ", virtual display is mirrored";
    else                     s += ", virtual display has its own source";
    return s;
}

VirtualDisplayVDD::TopologyState VirtualDisplayVDD::queryTopology() const {
    TopologyState st;
#ifdef _WIN32
    QVector<DISPLAYCONFIG_PATH_INFO> paths;
    QVector<DISPLAYCONFIG_MODE_INFO> modes;
    if (!queryPaths(paths, modes, QDC_ONLY_ACTIVE_PATHS)) return st;

    const int n = static_cast<int>(paths.size());
    st.valid = true;
    st.activePaths = n;

    for (int i = 0; i < n; i++) {
        const bool virt = isVirtualTarget(paths[i]);
        if (virt) st.virtualActive = true;

        for (int j = 0; j < n; j++) {
            if (i == j) continue;
            if (sourceKey(paths[i]) != sourceKey(paths[j])) continue;
            // Same source, different target — that is the definition of clone.
            st.anyCloned = true;
            if (virt) st.virtualCloned = true;
        }
    }
#endif
    return st;
}

QString VirtualDisplayVDD::topologyName(Topology mode) {
    switch (mode) {
        case Topology::Extend:       return QStringLiteral("Extend");
        case Topology::Duplicate:    return QStringLiteral("Duplicate");
        case Topology::InternalOnly: return QStringLiteral("PC screen only");
        case Topology::ExternalOnly: return QStringLiteral("Second screen only");
    }
    return QStringLiteral("Unknown");
}

bool VirtualDisplayVDD::applyTopology(Topology mode) {
#ifdef _WIN32
    // These are exactly the four Win+P projection modes. Windows restores the
    // saved topology for whichever is requested.
    UINT32 flag = SDC_TOPOLOGY_EXTEND;
    switch (mode) {
        case Topology::Extend:       flag = SDC_TOPOLOGY_EXTEND;   break;
        case Topology::Duplicate:    flag = SDC_TOPOLOGY_CLONE;    break;
        case Topology::InternalOnly: flag = SDC_TOPOLOGY_INTERNAL; break;
        case Topology::ExternalOnly: flag = SDC_TOPOLOGY_EXTERNAL; break;
    }

    LONG r = SetDisplayConfig(0, nullptr, 0, nullptr, flag | SDC_APPLY);
    if (r == ERROR_SUCCESS) {
        VDD_LOG("VDD: Applied topology " + topologyName(mode));
        emit statusChanged("Display mode: " + topologyName(mode));
        return true;
    }
    VDD_LOG(QString("VDD: Topology %1 failed (code %2)").arg(topologyName(mode)).arg(r));
    if (mode != Topology::Extend) {
        emit error(QString("Windows refused the '%1' display mode (code %2).")
                       .arg(topologyName(mode)).arg(r));
    }
#else
    Q_UNUSED(mode);
#endif
    return false;
}

bool VirtualDisplayVDD::applyExtendTopology() {
    return applyTopology(Topology::Extend);
}

bool VirtualDisplayVDD::applyExtendTopologySupplied() {
#ifdef _WIN32
    // SDC_TOPOLOGY_EXTEND only restores a topology Windows has already saved.
    // When there is none (common the first time a VDD monitor appears) we build
    // the path set ourselves: keep exactly the targets that are active now, but
    // give each one a source no other target uses.
    QVector<DISPLAYCONFIG_PATH_INFO> all;
    QVector<DISPLAYCONFIG_MODE_INFO> allModes;
    if (!queryPaths(all, allModes, QDC_ALL_PATHS)) {
        VDD_LOG("VDD: QueryDisplayConfig(QDC_ALL_PATHS) failed");
        return false;
    }

    // The targets we must keep lit — never activate anything new.
    QSet<QString> wantedTargets;
    for (const auto& p : all) {
        if (p.flags & DISPLAYCONFIG_PATH_ACTIVE) wantedTargets.insert(targetKey(p));
    }
    if (wantedTargets.isEmpty()) return false;

    QVector<DISPLAYCONFIG_PATH_INFO> chosen;
    QSet<QString> usedSources;
    QSet<QString> placedTargets;

    auto take = [&](const DISPLAYCONFIG_PATH_INFO& p) {
        DISPLAYCONFIG_PATH_INFO path = p;
        path.flags |= DISPLAYCONFIG_PATH_ACTIVE;
        // Dictate topology only — let Windows pick resolutions and refresh rates.
        path.sourceInfo.modeInfoIdx = DISPLAYCONFIG_PATH_MODE_IDX_INVALID;
        path.targetInfo.modeInfoIdx = DISPLAYCONFIG_PATH_MODE_IDX_INVALID;
        chosen.append(path);
        usedSources.insert(sourceKey(p));
        placedTargets.insert(targetKey(p));
    };

    // Pass 1 — every active target keeps its current source if nothing else claimed it.
    for (const auto& p : all) {
        if (!(p.flags & DISPLAYCONFIG_PATH_ACTIVE)) continue;
        if (placedTargets.contains(targetKey(p))) continue;
        if (usedSources.contains(sourceKey(p))) continue;  // loser of a clone pair
        take(p);
    }

    // Pass 2 — targets that lost the source race get re-homed onto a free one.
    for (const auto& p : all) {
        if (!wantedTargets.contains(targetKey(p))) continue;
        if (placedTargets.contains(targetKey(p))) continue;
        if (usedSources.contains(sourceKey(p))) continue;
        take(p);
    }

    if (placedTargets.size() != wantedTargets.size()) {
        VDD_LOG(QString("VDD: Could only give %1 of %2 displays a unique source")
                    .arg(placedTargets.size()).arg(wantedTargets.size()));
        return false;
    }

    const UINT32 base = SDC_APPLY | SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_ALLOW_CHANGES;
    const UINT32 count = static_cast<UINT32>(chosen.size());
    LONG r = SetDisplayConfig(count, chosen.data(), 0, nullptr, base | SDC_SAVE_TO_DATABASE);
    if (r != ERROR_SUCCESS) {
        VDD_LOG(QString("VDD: SetDisplayConfig failed (code %1), retrying without save").arg(r));
        r = SetDisplayConfig(count, chosen.data(), 0, nullptr, base);
    }
    if (r == ERROR_SUCCESS) {
        VDD_LOG(QString("VDD: Applied explicit extend topology across %1 display(s)")
                    .arg(chosen.size()));
        return true;
    }
    VDD_LOG(QString("VDD: Explicit extend topology failed (code %1)").arg(r));
#endif
    return false;
}

// Stash the primary display's current mode so a topology change can be undone.
void VirtualDisplayVDD::capturePrimaryMode() {
#ifdef _WIN32
    static_assert(sizeof(DEVMODEW) <= sizeof(m_savedPrimaryMode),
                  "m_savedPrimaryMode is too small for DEVMODEW");
    DEVMODEW dm = {};
    dm.dmSize = sizeof(dm);
    m_havePrimaryMode = EnumDisplaySettingsW(nullptr, ENUM_CURRENT_SETTINGS, &dm);
    if (m_havePrimaryMode) memcpy(m_savedPrimaryMode, &dm, sizeof(dm));
#endif
}

// Put the primary display back to the resolution and refresh rate it had before
// a topology change. No-op when nothing moved.
void VirtualDisplayVDD::restorePrimaryMode() {
#ifdef _WIN32
    if (!m_havePrimaryMode) return;
    DEVMODEW before = {};
    memcpy(&before, m_savedPrimaryMode, sizeof(before));

    DEVMODEW now = {};
    now.dmSize = sizeof(now);
    if (!EnumDisplaySettingsW(nullptr, ENUM_CURRENT_SETTINGS, &now)) return;

    if (now.dmPelsWidth == before.dmPelsWidth &&
        now.dmPelsHeight == before.dmPelsHeight &&
        now.dmDisplayFrequency == before.dmDisplayFrequency) {
        return;   // untouched
    }

    VDD_LOG(QString("VDD: Topology change altered the primary (%1x%2@%3Hz -> "
                    "%4x%5@%6Hz) — restoring")
                .arg(before.dmPelsWidth).arg(before.dmPelsHeight).arg(before.dmDisplayFrequency)
                .arg(now.dmPelsWidth).arg(now.dmPelsHeight).arg(now.dmDisplayFrequency));

    DEVMODEW target = before;
    target.dmSize = sizeof(target);
    target.dmFields = DM_PELSWIDTH | DM_PELSHEIGHT | DM_DISPLAYFREQUENCY | DM_BITSPERPEL;

    // CDS_NORESET + an explicit commit, NOT a bare CDS_UPDATEREGISTRY.
    //
    // Applying a primary mode change immediately makes Windows re-evaluate the
    // whole topology, which detached the virtual displays that had just been
    // extended — every receiver then found nothing to capture, fell through to
    // creating another display, and the app ended up restarting the driver in a
    // loop. Staging the change and committing once keeps it a mode change
    // rather than a topology event.
    LONG r = ChangeDisplaySettingsExW(nullptr, &target, nullptr,
                                      CDS_UPDATEREGISTRY | CDS_NORESET, nullptr);
    if (r == DISP_CHANGE_SUCCESSFUL) {
        r = ChangeDisplaySettingsExW(nullptr, nullptr, nullptr, 0, nullptr);
    }
    if (r != DISP_CHANGE_SUCCESSFUL) {
        VDD_LOG("VDD: Could not restore the primary display mode — " + dispChangeName(r));
        return;
    }
    VDD_LOG("VDD: Primary display mode restored");

    // A working extended desktop matters more than an exact refresh rate. If
    // the restore re-mirrored things anyway, put extend back and leave the mode.
    const TopologyState after = queryTopology();
    if (after.valid && after.anyCloned) {
        VDD_LOG("VDD: Restoring the primary re-mirrored the desktop — "
                "re-applying Extend and keeping the current refresh rate");
        applyTopology(Topology::Extend);
    }
#endif
}

// Raise a virtual display to the preferred resolution.
//
// Done as its own call, using a mode the driver actually advertises. Bundling
// the resolution into the positioning DEVMODE meant it inherited that call's
// DISP_CHANGE_FAILED, so streams stayed at the VDD's 800x600 default. And a
// synthesised 1920x1080@60 is the usual reason a mode change is refused —
// EnumDisplaySettings lists what the driver will actually accept, so pick from
// there instead of inventing one.
#ifdef _WIN32
// The first x past the right edge of every attached display except this one.
//
// Windows treats position and size as one change, and rejects a layout where
// two displays overlap - DISP_CHANGE_FAILED, with nothing said about why. The
// virtual displays are laid out while they are all 800x600, so the slots are
// 800 apart; raising one to 1920 wide makes it run into its neighbour, and the
// resize is refused. That is the whole story of a stream going out at 800x600
// on a machine with three virtual displays.
static LONG freeXBeyondOthers(const std::wstring& exclude) {
    LONG edge = 0;
    DISPLAY_DEVICEW dd = {};
    dd.cb = sizeof(dd);
    for (DWORD i = 0; EnumDisplayDevicesW(nullptr, i, &dd, 0); i++) {
        const bool attached = (dd.StateFlags & DISPLAY_DEVICE_ATTACHED_TO_DESKTOP) != 0;
        if (attached && exclude != dd.DeviceName) {
            DEVMODEW dm = {};
            dm.dmSize = sizeof(dm);
            if (EnumDisplaySettingsW(dd.DeviceName, ENUM_CURRENT_SETTINGS, &dm)) {
                edge = qMax(edge, dm.dmPosition.x + static_cast<LONG>(dm.dmPelsWidth));
            }
        }
        dd = {};
        dd.cb = sizeof(dd);
    }
    return edge;
}
#endif

bool VirtualDisplayVDD::setVirtualDisplayResolution(const QString& deviceName,
                                                    int width, int height) {
#ifdef _WIN32
    if (deviceName.isEmpty() || width <= 0 || height <= 0) return false;
    const std::wstring wname = deviceName.toStdWString();

    DEVMODEW current = {};
    current.dmSize = sizeof(current);
    if (EnumDisplaySettingsW(wname.c_str(), ENUM_CURRENT_SETTINGS, &current) &&
        static_cast<int>(current.dmPelsWidth) == width &&
        static_cast<int>(current.dmPelsHeight) == height) {
        return true;   // already there
    }

    // Find the advertised mode closest to what we want: exact size, highest
    // refresh rate, 32bpp.
    DEVMODEW best = {};
    bool found = false;
    DEVMODEW probe = {};
    probe.dmSize = sizeof(probe);
    for (DWORD i = 0; EnumDisplaySettingsW(wname.c_str(), i, &probe); i++) {
        if (static_cast<int>(probe.dmPelsWidth) == width &&
            static_cast<int>(probe.dmPelsHeight) == height &&
            probe.dmBitsPerPel == 32) {
            if (!found || probe.dmDisplayFrequency > best.dmDisplayFrequency) {
                best = probe;
                found = true;
            }
        }
        probe = {};
        probe.dmSize = sizeof(probe);
    }

    if (!found) {
        VDD_LOG(QString("VDD: %1 does not advertise %2x%3 — leaving it at %4x%5")
                    .arg(deviceName).arg(width).arg(height)
                    .arg(current.dmPelsWidth).arg(current.dmPelsHeight));
        return false;
    }

    // Keep the position; only the size changes.
    best.dmPosition = current.dmPosition;
    best.dmFields = DM_PELSWIDTH | DM_PELSHEIGHT | DM_BITSPERPEL |
                    DM_DISPLAYFREQUENCY | DM_POSITION;

    // Stage then commit, the same way attachVirtualDisplay() does. An immediate
    // CDS_UPDATEREGISTRY makes Windows re-evaluate the whole topology on the
    // spot, and a driver that is still settling — from a node install or a
    // topology switch a second earlier — answers DISP_CHANGE_FAILED. Staging
    // the change and committing separately survives that; a short retry covers
    // the rest.
    LONG r = DISP_CHANGE_FAILED;
    bool relocated = false;
    for (int attempt = 0; attempt < 3; attempt++) {
        if (attempt > 0) QThread::msleep(900);

        // Keep the position on the first try - a display already sitting
        // somewhere sensible should stay there. After that, move it clear of
        // everything else first: at its new size it may no longer fit the gap
        // it was laid out into, and an overlapping layout is refused outright.
        if (attempt == 1) {
            const LONG parkX = freeXBeyondOthers(wname);
            if (parkX != best.dmPosition.x) {
                VDD_LOG(QString("VDD: %1 will not fit where it is at %2x%3 — "
                                "moving it to x=%4 first")
                            .arg(deviceName).arg(width).arg(height).arg(parkX));
                best.dmPosition.x = parkX;
                best.dmPosition.y = 0;
                relocated = true;
            }
        }

        r = ChangeDisplaySettingsExW(wname.c_str(), &best, nullptr,
                                     CDS_UPDATEREGISTRY | CDS_NORESET, nullptr);
        if (r != DISP_CHANGE_SUCCESSFUL) continue;

        r = ChangeDisplaySettingsExW(nullptr, nullptr, nullptr, 0, nullptr);
        if (r == DISP_CHANGE_SUCCESSFUL) break;
    }
    if (r != DISP_CHANGE_SUCCESSFUL) {
        VDD_LOG(QString("VDD: Could not set %1 to %2x%3 — %4")
                    .arg(deviceName).arg(width).arg(height).arg(dispChangeName(r)));
        return false;
    }

    VDD_LOG(QString("VDD: %1 set to %2x%3 @ %4Hz")
                .arg(deviceName).arg(width).arg(height).arg(best.dmDisplayFrequency));

    // Lay the row out again now that this one is its final size, so the gaps
    // match the displays rather than the sizes they happened to boot at.
    if (relocated) positionVirtualDisplay();
    return true;
#else
    Q_UNUSED(deviceName); Q_UNUSED(width); Q_UNUSED(height);
    return false;
#endif
}

bool VirtualDisplayVDD::positionVirtualDisplay() {
#ifdef _WIN32
    // Find the primary so we can park the virtual display just past its right edge.
    DEVMODEW primaryDm = {};
    primaryDm.dmSize = sizeof(primaryDm);
    if (!EnumDisplaySettingsW(nullptr, ENUM_CURRENT_SETTINGS, &primaryDm)) {
        VDD_LOG("VDD: Could not read primary display settings");
        return false;
    }

    // The desktop may already extend past the primary (real second monitor);
    // park the virtual display beyond everything so nothing overlaps.
    LONG rightEdge = static_cast<LONG>(primaryDm.dmPelsWidth);
    DISPLAY_DEVICEW scan = {};
    scan.cb = sizeof(scan);
    for (DWORD i = 0; EnumDisplayDevicesW(nullptr, i, &scan, 0); i++) {
        if (scan.StateFlags & DISPLAY_DEVICE_ATTACHED_TO_DESKTOP) {
            DEVMODEW dm = {};
            dm.dmSize = sizeof(dm);
            if (EnumDisplaySettingsW(scan.DeviceName, ENUM_CURRENT_SETTINGS, &dm) &&
                !looksVirtual(QString::fromWCharArray(scan.DeviceString))) {
                rightEdge = qMax(rightEdge, dm.dmPosition.x + static_cast<LONG>(dm.dmPelsWidth));
            }
        }
        scan = {};
        scan.cb = sizeof(scan);
    }

    // Collect the attached virtual displays first, then lay them out in one pass.
    //
    // The previous version advanced the layout cursor only when a move
    // succeeded, and skipped displays already in place without advancing at
    // all — so with several virtual displays every one of them targeted the
    // same x, overlapped, and Windows rejected the lot. A real four-display
    // machine logged three consecutive "code -1" failures for exactly this.
    struct VirtualMon { QString name; DEVMODEW mode; };
    QVector<VirtualMon> virtuals;

    DISPLAY_DEVICEW dd = {};
    dd.cb = sizeof(dd);
    for (DWORD i = 0; EnumDisplayDevicesW(nullptr, i, &dd, 0); i++) {
        if ((dd.StateFlags & DISPLAY_DEVICE_ATTACHED_TO_DESKTOP) &&
            looksVirtual(QString::fromWCharArray(dd.DeviceString))) {
            DEVMODEW dm = {};
            dm.dmSize = sizeof(dm);
            if (EnumDisplaySettingsW(dd.DeviceName, ENUM_CURRENT_SETTINGS, &dm)) {
                virtuals.append({QString::fromWCharArray(dd.DeviceName), dm});
            }
        }
        dd = {};
        dd.cb = sizeof(dd);
    }
    if (virtuals.isEmpty()) return false;

    bool moved = false;
    bool anyFailed = false;
    LONG cursorX = rightEdge;

    for (auto& vm : virtuals) {
        const LONG targetX = cursorX;
        // Advance unconditionally — the slot is spoken for whether or not the
        // move lands, otherwise the next display collides with this one.
        cursorX += static_cast<LONG>(vm.mode.dmPelsWidth);

        if (vm.mode.dmPosition.x == targetX && vm.mode.dmPosition.y == 0) {
            VDD_LOG(QString("VDD: %1 already at %2,0").arg(vm.name).arg(targetX));
            continue;
        }

        DEVMODEW dm = vm.mode;
        // Carry a resolution alongside the position: some indirect display
        // drivers reject a position-only DEVMODE.
        //
        dm.dmFields = DM_POSITION | DM_PELSWIDTH | DM_PELSHEIGHT;
        dm.dmPosition.x = targetX;
        dm.dmPosition.y = 0;

        LONG ret = ChangeDisplaySettingsExW(
            reinterpret_cast<LPCWSTR>(vm.name.utf16()), &dm, nullptr,
            CDS_UPDATEREGISTRY | CDS_NORESET, nullptr);

        if (ret != DISP_CHANGE_SUCCESSFUL) {
            // Retry with position alone, for drivers that dislike being told a
            // resolution they consider read-only.
            DEVMODEW posOnly = vm.mode;
            posOnly.dmFields = DM_POSITION;
            posOnly.dmPosition.x = targetX;
            posOnly.dmPosition.y = 0;
            ret = ChangeDisplaySettingsExW(
                reinterpret_cast<LPCWSTR>(vm.name.utf16()), &posOnly, nullptr,
                CDS_UPDATEREGISTRY | CDS_NORESET, nullptr);
        }

        if (ret == DISP_CHANGE_SUCCESSFUL) {
            moved = true;
            VDD_LOG(QString("VDD: Positioned %1 at %2,0 (%3x%4)")
                        .arg(vm.name).arg(targetX)
                        .arg(vm.mode.dmPelsWidth).arg(vm.mode.dmPelsHeight));
        } else {
            anyFailed = true;
            VDD_LOG(QString("VDD: Could not position %1 at %2,0 — %3")
                        .arg(vm.name).arg(targetX).arg(dispChangeName(ret)));
        }
    }

    // Commit every CDS_NORESET change at once.
    if (moved) {
        LONG commit = ChangeDisplaySettingsExW(nullptr, nullptr, nullptr, 0, nullptr);
        if (commit != DISP_CHANGE_SUCCESSFUL) {
            VDD_LOG("VDD: Layout commit returned " + dispChangeName(commit));
            return false;
        }
        VDD_LOG(QString("VDD: Laid out %1 virtual display(s) from x=%2 to x=%3")
                    .arg(virtuals.size()).arg(rightEdge).arg(cursorX));
    }
    if (anyFailed) {
        VDD_LOG("VDD: Some virtual displays could not be repositioned — "
                "they may overlap in Display Settings");
    }
    return moved;
#else
    return false;
#endif
}

bool VirtualDisplayVDD::ensureExtendedTopology() {
#ifdef _WIN32
    TopologyState before = queryTopology();
    if (!before.valid) {
        VDD_LOG("VDD: Topology query failed — cannot verify extend mode");
        return false;
    }
    VDD_LOG("VDD: Topology before: " + before.describe());

    if (!before.anyCloned) {
        positionVirtualDisplay();
        return true;
    }

    VDD_LOG("VDD: Desktop is mirrored — switching to extend...");

    // SDC_TOPOLOGY_EXTEND restores a SAVED topology, and that saved state
    // carries a mode for every display — including the one you are sitting in
    // front of. Reported in the field: extending reset a 120Hz laptop panel to
    // 144Hz. Remember the primary's mode now and put it back afterwards, so
    // attaching a virtual display never silently changes the real screen.

    // SDC_TOPOLOGY_EXTEND can report success while leaving the desktop cloned
    // (it restores a *saved* topology, which may itself be stale), so verify
    // after each attempt rather than trusting the return code.
    for (int attempt = 0; attempt < 2; attempt++) {
        const bool applied = (attempt == 0) ? applyExtendTopology()
                                            : applyExtendTopologySupplied();
        if (!applied) continue;

        QThread::msleep(500);  // let the mode change settle before re-reading
        TopologyState after = queryTopology();
        VDD_LOG("VDD: Topology after: " + after.describe());
        if (after.valid && !after.anyCloned) {
            // The primary's mode is deliberately NOT restored here.
            //
            // Extending re-applies a saved topology that carries a mode for
            // every display, so a 120Hz panel can come back at 144Hz. Putting
            // it back, however carefully, re-triggered a topology change that
            // detached the virtual displays — twice, on real hardware. A
            // working extended desktop is worth more than the exact refresh
            // rate, so the mode is left where Windows puts it.
            positionVirtualDisplay();
            emit statusChanged("Display extended");
            return true;
        }
    }

    emit error("Could not switch the desktop out of mirrored mode. "
               "Set Display Settings → 'Extend these displays' manually.");
    return false;
#else
    return false;
#endif
}

bool VirtualDisplayVDD::createVirtualDisplay(int width, int height, int refreshRate,
                                            bool allowUiHelper) {
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

    // Ensure VDD Control is running (provides the named pipe interface).
    // Skipped on the automatic path: launching it throws the driver's console
    // over whatever the user is doing and blocks for ten seconds.
    if (allowUiHelper) ensureVddControlRunning();

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
            VDD_LOG("VDD: Display not in monitor list — trying to activate/extend...");
            activateVirtualDisplay();
            QThread::msleep(1000);
            outputIdx = findVirtualDisplayOutput();
        }
        // Windows re-applies the last projection mode to newly attached monitors,
        // so a fresh VDD often comes up mirrored. Force extend before capture.
        ensureExtendedTopology();
        emit virtualDisplayCreated(outputIdx);
        return true;
    }

    // Method 2: settings file + driver restart.
    //
    // On this driver monitors come from device nodes, so this can report success
    // while producing nothing — it did exactly that in the field, appending an
    // entry per attempt and restarting the driver under a live stream. Snapshot
    // the monitor count so the result can be verified and rolled back.
    const int monitorsBefore = enumerateMonitors().size();
    VDD_LOG("VDD: Named pipe unavailable, trying settings file method...");
    auto displays = readVddSettings();
    const auto displaysBefore = displays;
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

    QThread::msleep(1500);
    if (enumerateMonitors().size() <= monitorsBefore) {
        // Nothing appeared. Undo the settings entry so repeated attempts do not
        // leave a growing list of phantom displays behind.
        VDD_LOG("VDD: Settings file written but no new monitor appeared — "
                "this driver needs a new device node, which requires administrator "
                "rights. Rolling the settings file back.");
        writeVddSettings(displaysBefore);
        emit error("Could not add a virtual display. Adding one needs administrator "
                   "rights on this driver.");
        return false;
    }

    m_createdDisplayCount++;
    emit statusChanged(QString("Virtual display created: %1x%2 @ %3Hz")
                           .arg(width).arg(height).arg(refreshRate));

    QThread::msleep(2000);
    int outputIdx = findVirtualDisplayOutput();
    if (outputIdx < 0) {
        VDD_LOG("VDD: Display not in monitor list — trying to activate/extend...");
        activateVirtualDisplay();
        QThread::msleep(1000);
        outputIdx = findVirtualDisplayOutput();
    }
    if (outputIdx < 0) {
        VDD_LOG("VDD: Virtual display still not found — it may need manual 'Extend' in Display Settings");
    }
    ensureExtendedTopology();
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

// True if Windows still reports a virtual monitor after a removal attempt.
static bool anyVirtualMonitorLeft(const QVector<VirtualDisplayVDD::MonitorInfo>& mons) {
    for (const auto& m : mons) {
        if (m.isVirtual) return true;
    }
    return false;
}

bool VirtualDisplayVDD::removeAllVirtualDisplays() {
    if (!m_vddInstalled) return false;

    // Preferred: ask the driver directly.
    tryNamedPipe("{\"command\":\"removeAll\"}");

    // Then the settings file, for versions driven by it.
    if (writeVddSettings({})) {
        notifyDriverRefresh();
    }

    // Verify rather than assume. On MttVDD builds each monitor comes from a
    // root-enumerated device node and the settings file is empty, so both
    // routes above report success while every monitor is still attached —
    // which is why "Remove" appeared to do nothing.
    QThread::msleep(500);
    if (!anyVirtualMonitorLeft(enumerateMonitors()) && enumerateVddDevices().isEmpty()) {
        m_createdDisplayCount = 0;
        emit virtualDisplayRemoved();
        emit statusChanged("Virtual displays removed");
        return true;
    }

    VDD_LOG("VDD: Monitors persist after pipe/settings removal — removing device nodes");
    return removeVddDevices(0);
}

int VirtualDisplayVDD::virtualDisplayCount() const {
    return m_createdDisplayCount;
}

// ─── Monitor Enumeration ───────────────────────────────────────────────────────

QVector<VirtualDisplayVDD::MonitorInfo> VirtualDisplayVDD::enumerateMonitors() const {
    QVector<MonitorInfo> result;

#ifdef _WIN32
    // Method 1: DXGI enumeration (only sees attached/active displays)
    IDXGIFactory1* factory = nullptr;
    HRESULT hr = CreateDXGIFactory1(__uuidof(IDXGIFactory1), (void**)&factory);
    if (FAILED(hr)) {
        VDD_LOG("VDD: CreateDXGIFactory1 failed");
    } else {
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

                // Ask Windows what drives this display rather than trusting the
                // DXGI adapter description, which names the rendering GPU.
                const QString devStrings = displayAdapterString(info.name);
                info.isVirtual = looksVirtual(adapterName) || looksVirtual(devStrings);
                if (info.isVirtual && !looksVirtual(adapterName)) {
                    // Show the useful name in the picker, not the host GPU.
                    info.adapterName = "Virtual Display Driver";
                }

                result.append(info);
                output->Release();
            }
            adapter->Release();
        }
        factory->Release();
    }

    // Method 2: EnumDisplayDevices — finds ALL displays including disconnected virtual ones
    // that DXGI misses. This is needed because virtual displays may not be "attached"
    // to the desktop yet.
    DISPLAY_DEVICEW dd = {};
    dd.cb = sizeof(dd);
    for (DWORD i = 0; EnumDisplayDevicesW(nullptr, i, &dd, 0); i++) {
        // Skip inactive devices unless they look virtual
        QString devName = QString::fromWCharArray(dd.DeviceName);
        QString devString = QString::fromWCharArray(dd.DeviceString);
        QString lowerString = devString.toLower();

        bool isVirtual = lowerString.contains("virtual") ||
                         lowerString.contains("indirect") ||
                         lowerString.contains("idd") ||
                         lowerString.contains("vdd") ||
                         lowerString.contains("mtt");

        // Check if this device is already in our DXGI results
        bool alreadyFound = false;
        for (const auto& existing : result) {
            if (existing.name == devName) {
                alreadyFound = true;
                break;
            }
        }

        if (!alreadyFound && isVirtual) {
            MonitorInfo info;
            // StateFlags is the only reliable answer. The resolution below can
            // be a stale persisted mode for a display that is not attached.
            info.attached = (dd.StateFlags & DISPLAY_DEVICE_ATTACHED_TO_DESKTOP) != 0;
            // These indices are NOT DXGI indices — this branch only runs for
            // displays DXGI could not enumerate (typically a VDD that is not
            // attached to the desktop yet). Publishing the EnumDisplayDevices
            // ordinal as an adapter index sent the capture path to the wrong
            // adapter, which is what forced the slow GDI fallback. The device
            // name below is the authoritative key; ScreenCaptureWin resolves
            // the real adapter/output from it.
            info.adapterIndex = 0;
            info.outputIndex = 0;
            info.name = devName;
            info.adapterName = devString;
            info.isVirtual = true;

            // Get resolution from display settings
            DEVMODEW dm = {};
            dm.dmSize = sizeof(dm);
            if (EnumDisplaySettingsW(dd.DeviceName, ENUM_CURRENT_SETTINGS, &dm)) {
                info.width = static_cast<int>(dm.dmPelsWidth);
                info.height = static_cast<int>(dm.dmPelsHeight);
            } else if (EnumDisplaySettingsW(dd.DeviceName, ENUM_REGISTRY_SETTINGS, &dm)) {
                info.width = static_cast<int>(dm.dmPelsWidth);
                info.height = static_cast<int>(dm.dmPelsHeight);
            } else {
                // Use requested resolution from settings
                info.width = 1920;
                info.height = 1080;
            }

            VDD_LOG(QString("VDD: Found virtual display via EnumDisplayDevices: %1 (%2) %3x%4 "
                            "flags=0x%5 attached=%6")
                        .arg(devName, devString).arg(info.width).arg(info.height)
                        .arg(dd.StateFlags, 0, 16)
                        .arg(info.attached ? "yes" : "NO"));
            result.append(info);
        }
        dd = {};
        dd.cb = sizeof(dd);
    }
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

// ─── VDD Device Nodes ─────────────────────────────────────────────────────────

QVector<VirtualDisplayVDD::VddDevice> VirtualDisplayVDD::enumerateVddDevices() const {
    QVector<VddDevice> devices;
#ifdef _WIN32
    HDEVINFO devInfo = SetupDiGetClassDevsW(&GUID_DEVCLASS_DISPLAY, nullptr, nullptr,
                                            DIGCF_PRESENT);
    if (devInfo == INVALID_HANDLE_VALUE) return devices;

    SP_DEVINFO_DATA devData = {};
    devData.cbSize = sizeof(devData);
    for (DWORD i = 0; SetupDiEnumDeviceInfo(devInfo, i, &devData); i++) {
        wchar_t instanceId[MAX_DEVICE_ID_LEN] = {};
        if (!SetupDiGetDeviceInstanceIdW(devInfo, &devData, instanceId,
                                         MAX_DEVICE_ID_LEN, nullptr)) {
            continue;
        }
        const QString id = QString::fromWCharArray(instanceId);

        // VDD nodes are root-enumerated; a real GPU sits on PCI.
        if (!id.startsWith("ROOT\\", Qt::CaseInsensitive)) continue;

        wchar_t friendly[512] = {};
        QString name;
        if (SetupDiGetDeviceRegistryPropertyW(devInfo, &devData, SPDRP_FRIENDLYNAME,
                                              nullptr, reinterpret_cast<PBYTE>(friendly),
                                              sizeof(friendly), nullptr) ||
            SetupDiGetDeviceRegistryPropertyW(devInfo, &devData, SPDRP_DEVICEDESC,
                                              nullptr, reinterpret_cast<PBYTE>(friendly),
                                              sizeof(friendly), nullptr)) {
            name = QString::fromWCharArray(friendly);
        }

        // A root-enumerated display device IS a virtual one — real GPUs sit on
        // PCI. Matching only on the name was wrong: freshly created nodes
        // enumerate as ROOT\DISPLAY\000N and their friendly name is not
        // populated straight away, so a successful devcon install was counted
        // as "0 nodes added" and reported as a failure. Repeated attempts then
        // created ten nodes while telling the user nothing had worked.
        if (id.startsWith("ROOT\\DISPLAY", Qt::CaseInsensitive) ||
            looksVirtual(id) || looksVirtual(name)) {
            devices.append({id, name.isEmpty() ? QStringLiteral("Virtual Display Driver") : name});
        }
        devData = {};
        devData.cbSize = sizeof(devData);
    }
    SetupDiDestroyDeviceInfoList(devInfo);
#endif
    return devices;
}

bool VirtualDisplayVDD::addVddDeviceNode() {
    return addVddDeviceNodes(1);
}

bool VirtualDisplayVDD::waitForVirtualMonitors(int expected, int timeoutMs) const {
    if (expected <= 0) return true;

    QElapsedTimer clock;
    clock.start();
    int seenPresent = -1;
    int seenAttached = -1;
    while (clock.elapsed() < timeoutMs) {
        int present = 0;
        int attached = 0;
        for (const auto& mon : enumerateMonitors()) {
            if (!mon.isVirtual) continue;
            present++;
            if (mon.attached) attached++;
        }
        if (present != seenPresent || attached != seenAttached) {
            seenPresent = present;
            seenAttached = attached;
            VDD_LOG(QString("VDD: %1 virtual monitor(s) present, %2 attached to the "
                            "desktop, after %3 ms (want %4)")
                        .arg(present).arg(attached).arg(clock.elapsed()).arg(expected));
        }

        // Attached, not merely present.
        //
        // A device node shows up within milliseconds; Windows takes seconds
        // longer to put the monitor on the desktop. This used to count nodes
        // and report "3 of 3 virtual monitor(s) up after 5 ms", after which
        // every position, mode change and capture failed on displays that were
        // not there yet - each of which reads like its own bug.
        if (attached >= expected) {
            QThread::msleep(300);   // let the last one settle its mode list
            return true;
        }
        QThread::msleep(500);
    }

    // Both numbers, because which one fell short says what went wrong: no
    // monitors at all is a driver or settings problem, monitors present but
    // unattached is Windows refusing to put them on the desktop.
    VDD_LOG(QString("VDD: Timed out after %1 ms — %2 virtual monitor(s) present, "
                    "%3 attached, wanted %4")
                .arg(timeoutMs).arg(seenPresent).arg(seenAttached).arg(expected));
    return false;
}

bool VirtualDisplayVDD::ensureDisplayNodes(int desired) {
    if (desired <= 0) return true;

    const int have = enumerateVddDevices().size();
    if (have >= desired) return true;

    VDD_LOG(QString("VDD: %1 virtual display node(s) present, preparing %2 so "
                    "receivers can each get a screen without restarting the driver "
                    "mid-stream")
                .arg(have).arg(desired));
    return addVddDeviceNodes(desired - have);
}

// Create root-enumerated VDD device nodes, elevated.
//
// The settings-file route reports success and produces nothing on this driver:
// monitors come from device nodes, so writing vdd_settings.xml just grew the
// file by one entry per attempt while restarting the driver under a live
// stream. devcon install is what actually adds a monitor, and it needs admin.
//
// Several nodes go into one elevated command deliberately. Installing a node
// makes the driver tear down and re-enumerate *all* of its monitors, so every
// \\.\DISPLAYn name it owns changes and any capture running against one of them
// dies. Creating the whole pool in a single pass means that disruption happens
// once, while nothing is streaming, instead of once per receiver.
bool VirtualDisplayVDD::addVddDeviceNodes(int count) {
#ifdef _WIN32
    if (m_vddPath.isEmpty() || count <= 0) return false;

    QString inf = m_vddPath + "/MttVDD.inf";
    if (!QFileInfo::exists(inf)) {
        QDir dir(m_vddPath);
        const QStringList infs = dir.entryList({"*.inf"}, QDir::Files);
        if (infs.isEmpty()) {
            VDD_LOG("VDD: No .inf in " + m_vddPath + " — cannot add a display");
            return false;
        }
        inf = m_vddPath + "/" + infs.first();
    }

    // Run through cmd.exe so the tool's own output can be captured to a file.
    // Without it this failed silently - "Device nodes 1 -> 1" with no clue why -
    // and pnputil /add-driver in particular only adds the driver to the store
    // WITHOUT creating a device node, so it can "succeed" and add no monitor.
    const QString devcon = m_vddPath + "/devcon.exe";
    const QString logPath = QDir::toNativeSeparators(
        QDir::temp().filePath("bettercast_vdd_add.log"));
    QFile::remove(logPath);

    QString one;
    if (QFileInfo::exists(devcon)) {
        one = QString("\"%1\" install \"%2\" Root\\MttVDD")
                  .arg(QDir::toNativeSeparators(devcon),
                       QDir::toNativeSeparators(inf));
    } else {
        one = QString("pnputil.exe /add-driver \"%1\" /install")
                  .arg(QDir::toNativeSeparators(inf));
    }

    // Repeat the install inside the one elevated shell: one UAC prompt for the
    // whole pool. `&` and not `&&` — a node that fails should not stop the rest.
    QStringList steps;
    for (int i = 0; i < count; i++) steps << one;
    const QString inner = steps.join(" & ");

    // cmd /s /c "<whole thing>" — the outer quotes and /s are required.
    //
    // Without them, cmd sees a command starting with a quote, applies its own
    // quote-stripping rule and mangles the line: the previous version returned
    // exit code 1 having created nothing and written no log. Direct
    // ShellExecuteEx on devcon.exe worked fine; wrapping it for logging is what
    // broke it. /s tells cmd to strip exactly the outer pair and leave the rest.
    const QString exe = "cmd.exe";
    const QString args = QString("/s /c \"%1 > \"%2\" 2>&1\"").arg(inner, logPath);
    VDD_LOG("VDD: Running elevated: " + inner);

    const int before = enumerateVddDevices().size();
    emit statusChanged(count == 1
        ? QString("Adding a virtual display — approve the administrator prompt")
        : QString("Adding %1 virtual displays — approve the administrator prompt")
              .arg(count));

    SHELLEXECUTEINFOW sei = {};
    sei.cbSize = sizeof(sei);
    sei.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC;
    sei.lpVerb = L"runas";
    const std::wstring wexe = QDir::toNativeSeparators(exe).toStdWString();
    const std::wstring wargs = args.toStdWString();
    sei.lpFile = wexe.c_str();
    sei.lpParameters = wargs.c_str();
    sei.nShow = SW_HIDE;

    if (!ShellExecuteExW(&sei)) {
        const DWORD err = GetLastError();
        VDD_LOG(QString("VDD: Could not launch the display-creation helper (error %1)").arg(err));
        emit error(err == ERROR_CANCELLED
                       ? QString("Adding a virtual display needs administrator approval.")
                       : QString("Could not add a virtual display (error %1).").arg(err));
        return false;
    }
    DWORD exitCode = 0xFFFFFFFF;
    if (sei.hProcess) {
        WaitForSingleObject(sei.hProcess, 60000);
        GetExitCodeProcess(sei.hProcess, &exitCode);
        CloseHandle(sei.hProcess);
    }
    VDD_LOG(QString("VDD: Helper exit code %1").arg(static_cast<int>(exitCode)));

    // Surface whatever the tool said — this is the diagnostic that was missing.
    QFile out(logPath);
    if (out.open(QIODevice::ReadOnly | QIODevice::Text)) {
        const QString text = QString::fromLocal8Bit(out.readAll()).trimmed();
        out.close();
        const QStringList lines = text.split(QChar('\n'), Qt::SkipEmptyParts);
        for (const QString& line : lines) {
            VDD_LOG("VDD: > " + line.trimmed());
        }
    } else {
        VDD_LOG("VDD: (no output captured from the helper)");
    }

    QThread::msleep(1500);
    const int after = enumerateVddDevices().size();
    VDD_LOG(QString("VDD: Device nodes %1 -> %2").arg(before).arg(after));
    if (after <= before) {
        emit error("The virtual display was not created. Try running BetterCast as "
                   "administrator, or add one from VDD Control.");
        return false;
    }

    // A device node exists well before its monitor does. The previous version
    // stopped at the sleep above and attached immediately, which is why every
    // attach right after an install came back DISP_CHANGE_FAILED — the driver
    // was still bringing its monitors up. Wait for them to actually appear.
    waitForVirtualMonitors(after, 20000);

    m_createdDisplayCount = after;
    emit virtualDisplayCreated(-1);
    return true;
#else
    return false;
#endif
}

bool VirtualDisplayVDD::removeVddDevices(int keep) {
#ifdef _WIN32
    const auto devices = enumerateVddDevices();
    if (devices.isEmpty()) {
        VDD_LOG("VDD: No virtual display device nodes found");
        return false;
    }
    if (devices.size() <= keep) {
        VDD_LOG(QString("VDD: %1 device node(s) present, keeping %2 — nothing to remove")
                    .arg(devices.size()).arg(keep));
        return true;
    }

    // One command removing every stale node, so the user sees a single UAC
    // prompt instead of one per display.
    QStringList parts;
    for (int i = keep; i < devices.size(); i++) {
        parts << QString("pnputil /remove-device \"%1\"").arg(devices[i].instanceId);
        VDD_LOG("VDD: Will remove " + devices[i].instanceId + " (" + devices[i].friendlyName + ")");
    }
    const QString args = "/c " + parts.join(" & ");

    emit statusChanged(QString("Removing %1 virtual display(s) — approve the "
                               "administrator prompt").arg(parts.size()));

    SHELLEXECUTEINFOW sei = {};
    sei.cbSize = sizeof(sei);
    sei.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC;
    sei.lpVerb = L"runas";          // elevate just this action, not the whole app
    sei.lpFile = L"cmd.exe";
    const std::wstring wargs = args.toStdWString();
    sei.lpParameters = wargs.c_str();
    sei.nShow = SW_HIDE;

    if (!ShellExecuteExW(&sei)) {
        const DWORD err = GetLastError();
        if (err == ERROR_CANCELLED) {
            VDD_LOG("VDD: Removal cancelled — administrator approval declined");
            emit error("Removing virtual displays needs administrator approval.");
        } else {
            VDD_LOG(QString("VDD: ShellExecuteEx failed (error %1)").arg(err));
            emit error(QString("Could not launch the removal helper (error %1).").arg(err));
        }
        return false;
    }

    if (sei.hProcess) {
        WaitForSingleObject(sei.hProcess, 60000);
        DWORD exitCode = 1;
        GetExitCodeProcess(sei.hProcess, &exitCode);
        CloseHandle(sei.hProcess);
        VDD_LOG(QString("VDD: Removal helper exit code %1").arg(exitCode));
    }

    const int remaining = enumerateVddDevices().size();
    VDD_LOG(QString("VDD: %1 virtual display device node(s) remain").arg(remaining));
    m_createdDisplayCount = remaining;
    emit virtualDisplayRemoved();
    emit statusChanged(QString("%1 virtual display(s) remaining").arg(remaining));
    return remaining <= keep;
#else
    Q_UNUSED(keep);
    return false;
#endif
}

// ─── VDD Settings File ────────────────────────────────────────────────────────

// Where the driver reads its settings — which is not where the driver package
// happens to be installed.
//
// MttVDD.dll contains, as wide strings, "C:\VirtualDisplayDriver",
// "\vdd_settings.xml" and "SOFTWARE\MikeTheTech\VirtualDisplayDriver": it
// looks in a fixed folder, with that registry key able to redirect it.
//
// This code used to write into whichever folder the .inf was installed from -
// C:\Program Files\BetterCast\VirtualDisplayDriver here - a file the driver
// never opens. So the driver ran on its built-in defaults no matter what
// BetterCast wrote, and a virtual display coming up at 800x600 was it saying
// so. Every "the mode is not advertised" and "could not set 1920x1080" failure
// downstream came from the same place.
QString VirtualDisplayVDD::vddSettingsPath() const {
    QString dir;
#ifdef _WIN32
    // The redirect wins when it is set, so an install that moved the folder
    // still works.
    HKEY key;
    if (RegOpenKeyExW(HKEY_LOCAL_MACHINE,
                      L"SOFTWARE\\MikeTheTech\\VirtualDisplayDriver",
                      0, KEY_READ, &key) == ERROR_SUCCESS) {
        for (const wchar_t* value : {L"SettingsPath", L"Path", L"InstallPath", L""}) {
            wchar_t buf[MAX_PATH] = {};
            DWORD size = sizeof(buf);
            if (RegQueryValueExW(key, value, nullptr, nullptr,
                                 reinterpret_cast<LPBYTE>(buf), &size) == ERROR_SUCCESS) {
                const QString candidate = QString::fromWCharArray(buf).trimmed();
                if (!candidate.isEmpty()) { dir = candidate; break; }
            }
        }
        RegCloseKey(key);
    }
#endif
    if (dir.isEmpty()) dir = "C:/VirtualDisplayDriver";
    return QDir(dir).filePath("vdd_settings.xml");
}

// The Virtual Display Driver's settings file, as the driver actually writes it:
//
//   <vdd_settings>
//     <monitors><count>1</count></monitors>
//     <gpu><friendlyname>default</friendlyname></gpu>
//     <global><g_refresh_rate>60</g_refresh_rate>...</global>
//     <resolutions>
//       <resolution><width>1920</width><height>1080</height>
//                   <refresh_rate>30</refresh_rate></resolution>
//     </resolutions>
//     <options>...</options>
//   </vdd_settings>
//
// This code used to invent its own shape - <VirtualDisplaySettings><Displays>
// <Display><Width> - and read that same shape back, so the writer and the
// reader agreed with each other and neither agreed with the driver. The reader
// therefore always reported no modes, which made the writer overwrite the file
// every time; and the overwrite deleted <monitors><count>, which is how the
// driver knows how many monitors to create, along with the GPU choice and the
// global refresh rates.
//
// Two things kept it hidden. The write needs administrator rights, and until
// that was fixed it failed silently, leaving the driver's own file in place.
// And a virtual display coming up at 800x600 looked like a resolution bug
// rather than what it was - the driver's first stock mode, because our modes
// had never reached it.
QVector<VirtualDisplayVDD::VddResolution> VirtualDisplayVDD::readVddSettings() const {
    QVector<VddResolution> displays;
    if (m_vddPath.isEmpty()) return displays;

    // The driver's real file first; the copy inside the install folder only as
    // a fallback, since that is the one nothing reads.
    QStringList candidates{ vddSettingsPath() };
    for (const auto& filename : kSettingsFiles) candidates << (m_vddPath + "/" + filename);

    for (const auto& path : candidates) {
        QFile file(path);
        if (!file.exists() || !file.open(QIODevice::ReadOnly)) continue;

        QXmlStreamReader xml(&file);
        VddResolution current = {0, 0, 0};
        bool inResolution = false;

        while (!xml.atEnd()) {
            xml.readNext();
            if (xml.isStartElement()) {
                const QString name = xml.name().toString().toLower();
                if (name == "resolution") {
                    inResolution = true;
                    current = {0, 0, 0};
                } else if (!inResolution) {
                    continue;   // width/height elsewhere in the file is not ours
                } else if (name == "width") {
                    current.width = xml.readElementText().toInt();
                } else if (name == "height") {
                    current.height = xml.readElementText().toInt();
                } else if (name == "refresh_rate" || name == "rate") {
                    // Only the first rate for a resolution: the driver allows
                    // several and this list is used to answer "is this size
                    // offered", where the rate does not matter.
                    const int r = xml.readElementText().toInt();
                    if (current.refreshRate == 0) current.refreshRate = r;
                }
            } else if (xml.isEndElement()) {
                if (xml.name().toString().toLower() != "resolution") continue;
                inResolution = false;
                if (current.width > 0 && current.height > 0) {
                    if (current.refreshRate == 0) current.refreshRate = 60;
                    displays.append(current);
                }
                current = {0, 0, 0};
            }
        }

        if (xml.hasError()) {
            VDD_LOG(QString("VDD: %1 could not be parsed (%2) — leaving it alone")
                        .arg(path, xml.errorString()));
        }
        file.close();
        if (!displays.isEmpty()) break;
    }

    return displays;
}

bool VirtualDisplayVDD::writeVddSettings(const QVector<VddResolution>& displays) {
    if (m_vddPath.isEmpty()) return false;

    const QString settingsPath = vddSettingsPath();
    if (settingsPath.isEmpty()) return false;

    // Build the file contents in memory so the same bytes can go down either
    // the direct or the elevated path.
    //
    // Copied through element by element, replacing only <resolutions>.
    // Everything else in that file belongs to the driver or to the user:
    // <monitors><count> decides how many monitors exist at all, <gpu> picks the
    // adapter, <global> holds the refresh rates applied to every mode, and
    // <options> carries EDID, HDR and logging switches. Rewriting the document
    // wholesale threw all of that away, which is what left a machine with four
    // device nodes and no monitor that would attach to anything.
    auto writeResolutions = [&displays](QXmlStreamWriter& xml) {
        xml.writeStartElement("resolutions");
        for (const auto& disp : displays) {
            xml.writeStartElement("resolution");
            xml.writeTextElement("width", QString::number(disp.width));
            xml.writeTextElement("height", QString::number(disp.height));
            xml.writeTextElement("refresh_rate", QString::number(disp.refreshRate));
            xml.writeEndElement();   // resolution
        }
        xml.writeEndElement();       // resolutions
    };

    QByteArray payload;
    bool rewrote = false;

    QFile existing(settingsPath);
    if (existing.open(QIODevice::ReadOnly)) {
        const QByteArray original = existing.readAll();
        existing.close();

        QXmlStreamReader in(original);
        QXmlStreamWriter out(&payload);
        out.setAutoFormatting(true);
        bool sawRoot = false;

        while (!in.atEnd() && !in.hasError()) {
            in.readNext();
            if (in.isStartElement() && in.name().toString().toLower() == "vdd_settings") {
                sawRoot = true;
            }
            if (in.isStartElement() && in.name().toString().toLower() == "resolutions") {
                writeResolutions(out);
                in.skipCurrentElement();   // drop the driver's list, keep ours
                continue;
            }
            if (in.isStartDocument())      out.writeStartDocument();
            else if (in.isEndDocument())   out.writeEndDocument();
            else if (in.isStartElement())  { out.writeStartElement(in.name().toString());
                                             out.writeAttributes(in.attributes()); }
            else if (in.isEndElement())    out.writeEndElement();
            else if (in.isCharacters() && !in.isWhitespace())
                                           out.writeCharacters(in.text().toString());
            else if (in.isComment())       out.writeComment(in.text().toString());
        }

        // Only trust the result if it was the driver's document and it parsed.
        rewrote = sawRoot && !in.hasError() && !payload.isEmpty();
        if (!rewrote) {
            payload.clear();
            VDD_LOG("VDD: " + settingsPath + " is not a settings file this "
                    "version understands — writing a fresh one");
        }
    }

    if (!rewrote) {
        // No file, or one that could not be parsed. Write a complete document
        // in the driver's own shape, including the parts we do not manage, so
        // a fresh file is still a valid one.
        QXmlStreamWriter xml(&payload);
        xml.setAutoFormatting(true);
        xml.writeStartDocument();
        xml.writeStartElement("vdd_settings");

        xml.writeStartElement("monitors");
        xml.writeTextElement("count", "1");
        xml.writeEndElement();

        xml.writeStartElement("gpu");
        xml.writeTextElement("friendlyname", "default");
        xml.writeEndElement();

        xml.writeStartElement("global");
        xml.writeTextElement("g_refresh_rate", "60");
        xml.writeEndElement();

        writeResolutions(xml);

        xml.writeStartElement("options");
        xml.writeTextElement("HardwareCursor", "true");
        xml.writeEndElement();

        xml.writeEndElement();   // vdd_settings
        xml.writeEndDocument();
    }

    // Attempt the plain write, and fall back to elevation only when it is
    // actually refused.
    //
    // The previous version asked QFileInfo::isWritable() about the directory
    // first and skipped the elevated path whenever it said yes. On Windows that
    // check reports the read-only *attribute*, not the ACL — it answers
    // "writable" for C:\Program Files even for a standard user. So the elevated
    // copy never ran, open() was denied, and the sole trace was a qWarning that
    // never reaches the in-app log: the settings file was never updated and
    // every virtual display stayed on the driver's 800x600 default. Try the
    // write; let the failure, not a prediction of it, choose the path.
    // The driver's folder is a fixed location that may not exist at all - it is
    // not created by installing the driver package, only by whatever put the
    // settings there. Try locally; the elevated path below creates it too, for
    // the usual case where C:\ is not writable by this user.
    const QString settingsDir = QFileInfo(settingsPath).absolutePath();
    if (!QDir(settingsDir).exists()) QDir().mkpath(settingsDir);

    bool wrote = false;
    QFile direct(settingsPath);
    if (direct.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        wrote = direct.write(payload) == payload.size();
        direct.close();
        if (!wrote) VDD_LOG("VDD: Short write to " + settingsPath);
    }

    if (!wrote) {
#ifdef _WIN32
        const QString stagePath = QDir::temp().filePath("bettercast_vdd_settings.xml");
        QFile stage(stagePath);
        if (!stage.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
            VDD_LOG("VDD: Cannot stage the settings file at " + stagePath);
            return false;
        }
        stage.write(payload);
        stage.close();

        // Copy into Program Files behind a single UAC prompt.
        VDD_LOG("VDD: " + settingsPath + " needs administrator rights — "
                "copying the new display modes into place elevated");
        // mkdir first, and ignore it failing because the folder is already
        // there: the driver's settings folder is a fixed path that nothing
        // else creates, so on a fresh machine the copy has nowhere to land.
        const QString args = QString("/s /c \"mkdir \"%1\" 2>nul & copy /Y \"%2\" \"%3\"\"")
                                 .arg(QDir::toNativeSeparators(settingsDir),
                                      QDir::toNativeSeparators(stagePath),
                                      QDir::toNativeSeparators(settingsPath));

        SHELLEXECUTEINFOW sei = {};
        sei.cbSize = sizeof(sei);
        sei.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC;
        sei.lpVerb = L"runas";
        sei.lpFile = L"cmd.exe";
        const std::wstring wargs = args.toStdWString();
        sei.lpParameters = wargs.c_str();
        sei.nShow = SW_HIDE;

        if (!ShellExecuteExW(&sei)) {
            VDD_LOG(QString("VDD: Elevated copy refused (error %1)").arg(GetLastError()));
            return false;
        }
        DWORD rc = 1;
        if (sei.hProcess) {
            WaitForSingleObject(sei.hProcess, 60000);
            GetExitCodeProcess(sei.hProcess, &rc);
            CloseHandle(sei.hProcess);
        }
        if (rc != 0) {
            VDD_LOG(QString("VDD: Elevated copy failed (exit %1)").arg(static_cast<int>(rc)));
            return false;
        }
#else
        VDD_LOG("VDD: Cannot write " + settingsPath);
        return false;
#endif
    }

    // Read it back rather than believing the return code — every long detour on
    // this driver has come from trusting a success that produced nothing.
    if (readVddSettings().isEmpty()) {
        VDD_LOG("VDD: " + settingsPath + " still reads back empty — the write did "
                                         "not stick");
        return false;
    }

    VDD_LOG(QString("VDD: Wrote %1 display mode(s) to %2")
                .arg(displays.size()).arg(settingsPath));
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
