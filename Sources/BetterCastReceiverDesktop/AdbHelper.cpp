#include "AdbHelper.h"
#include <QCoreApplication>
#include <QDebug>
#include <QFile>
#include <QDir>
#include <QProcess>
#include <QRegularExpression>
#include <QStandardPaths>
#include <QThread>

AdbHelper::AdbHelper(QObject* parent)
    : QObject(parent)
{
}

QString AdbHelper::findAdb() {
    if (!m_adbPath.isEmpty() && QFile::exists(m_adbPath)) {
        return m_adbPath;
    }

    QStringList candidates;

#ifdef _WIN32
    // Bundled with app (preferred — ships with the exe)
    candidates << QCoreApplication::applicationDirPath() + "/adb.exe";
    // Android SDK in AppData
    QString localAppData = qEnvironmentVariable("LOCALAPPDATA");
    if (!localAppData.isEmpty()) {
        candidates << localAppData + "/Android/Sdk/platform-tools/adb.exe";
    }
    QString userProfile = qEnvironmentVariable("USERPROFILE");
    if (!userProfile.isEmpty()) {
        candidates << userProfile + "/AppData/Local/Android/Sdk/platform-tools/adb.exe";
    }
#else
    // Bundled with app (preferred — ships with the AppImage)
    candidates << QCoreApplication::applicationDirPath() + "/adb";
    candidates << QCoreApplication::applicationDirPath() + "/../usr/bin/adb";
    // System paths
    candidates << "/usr/bin/adb";
    candidates << "/usr/local/bin/adb";
    candidates << "/opt/homebrew/bin/adb";
    candidates << QDir::homePath() + "/Android/Sdk/platform-tools/adb";
    candidates << QDir::homePath() + "/Library/Android/sdk/platform-tools/adb";
    candidates << QDir::homePath() + "/snap/android-studio/current/Android/Sdk/platform-tools/adb";
#endif

    for (const auto& path : candidates) {
        if (QFile::exists(path)) {
            m_adbPath = path;
            qDebug() << "ADB: Found at" << path;
            return m_adbPath;
        }
    }

    // Try PATH lookup as last resort
    QString fromPath = QStandardPaths::findExecutable("adb");
    if (!fromPath.isEmpty()) {
        m_adbPath = fromPath;
        qDebug() << "ADB: Found in PATH:" << fromPath;
        return m_adbPath;
    }

    qDebug() << "ADB: Not found on system";
    return {};
}

QString AdbHelper::findDevice() {
    QString output = runAdb({"devices"});
    if (output.isEmpty()) return {};

    QStringList serials;
    QStringList usbSerials;

    for (const auto& line : output.split('\n')) {
        QString trimmed = line.trimmed();
        if (trimmed.contains("\tdevice")) {
            QString serial = trimmed.split('\t').first().trimmed();
            if (!serial.isEmpty()) {
                serials << serial;
                // USB devices have numeric serials, WiFi have IP:port
                if (!serial.contains(':')) {
                    usbSerials << serial;
                }
            }
        }
    }

    if (serials.size() <= 1) {
        // 0 or 1 device — adb picks automatically
        m_deviceSerial.clear();
        return {};
    }

    // Prefer USB over WiFi
    m_deviceSerial = usbSerials.isEmpty() ? serials.first() : usbSerials.first();
    qDebug() << "ADB: Selected device" << m_deviceSerial << "from" << serials.size() << "devices";
    return m_deviceSerial;
}

QString AdbHelper::getDeviceIp() {
    // Get device IP via adb shell
    QStringList args;
    if (!m_deviceSerial.isEmpty()) {
        args << "-s" << m_deviceSerial;
    }
    args << "shell" << "ip" << "route" << "show" << "dev" << "wlan0";

    QString output = runAdb(args, 5000);
    // Parse: "... src 192.168.1.x ..."
    QRegularExpression re("src\\s+(\\d+\\.\\d+\\.\\d+\\.\\d+)");
    auto match = re.match(output);
    if (match.hasMatch()) {
        QString ip = match.captured(1);
        qDebug() << "ADB: Device WiFi IP:" << ip;
        return ip;
    }

    // Fallback: try wlan1 or other interfaces
    args.clear();
    if (!m_deviceSerial.isEmpty()) {
        args << "-s" << m_deviceSerial;
    }
    args << "shell" << "ip" << "-f" << "inet" << "addr" << "show";
    output = runAdb(args, 5000);

    // Look for non-loopback inet address
    for (const auto& line : output.split('\n')) {
        if (line.contains("inet ") && !line.contains("127.0.0.1")) {
            QRegularExpression re2("inet\\s+(\\d+\\.\\d+\\.\\d+\\.\\d+)");
            auto m = re2.match(line);
            if (m.hasMatch()) {
                QString ip = m.captured(1);
                qDebug() << "ADB: Device IP (fallback):" << ip;
                return ip;
            }
        }
    }

    qDebug() << "ADB: Could not determine device IP";
    return {};
}

bool AdbHelper::enableWirelessAdb() {
    // Get device IP first (while USB is still connected)
    m_deviceIp = getDeviceIp();
    if (m_deviceIp.isEmpty()) {
        qDebug() << "ADB: Cannot enable wireless — no device IP found (WiFi off?)";
        return false;
    }

    // Enable TCP/IP mode on port 5555
    QStringList args;
    if (!m_deviceSerial.isEmpty()) {
        args << "-s" << m_deviceSerial;
    }
    args << "tcpip" << "5555";

    emit statusChanged("Enabling wireless ADB...");
    QString output = runAdb(args, 15000);
    qDebug() << "ADB: tcpip 5555 result:" << output.trimmed();

    // Give the device a moment to switch to TCP mode
    QThread::msleep(1500);

    // Connect wirelessly
    QString connectTarget = m_deviceIp + ":5555";
    output = runAdb({"connect", connectTarget}, 10000);
    qDebug() << "ADB: connect" << connectTarget << "result:" << output.trimmed();

    if (output.contains("connected") || output.contains("already")) {
        emit statusChanged("Wireless ADB enabled — USB can be disconnected");
        qDebug() << "ADB: Wireless connection established to" << connectTarget;
        return true;
    }

    qDebug() << "ADB: Wireless connect failed, USB-only mode";
    return false;
}

bool AdbHelper::setupForward(uint16_t remotePort) {
    QString adb = findAdb();
    if (adb.isEmpty()) {
        emit statusChanged("ADB not found. Install Android SDK platform-tools.");
        return false;
    }

    emit statusChanged("Looking for Android device...");

    // Find device
    QString serial = findDevice();

    // Check we have at least one device
    QString devicesOutput = runAdb({"devices"});
    bool hasDevice = false;
    for (const auto& line : devicesOutput.split('\n')) {
        if (line.trimmed().contains("\tdevice")) {
            hasDevice = true;
            break;
        }
    }

    if (!hasDevice) {
        emit statusChanged("No Android device found. Enable USB Debugging and connect via USB.");
        return false;
    }

    emit statusChanged("Setting up ADB tunnel...");

    // Use a DIFFERENT local port to avoid conflict with our own receiver on 51820
    uint16_t localPort = remotePort + 1; // e.g., 51821 → android:51820

    // Run: adb [-s serial] forward tcp:localPort tcp:remotePort
    QStringList args;
    if (!serial.isEmpty()) {
        args << "-s" << serial;
    }
    args << "forward" << QString("tcp:%1").arg(localPort) << QString("tcp:%1").arg(remotePort);

    QString output = runAdb(args);

    // Verify by listing forwards
    QStringList verifyArgs;
    if (!serial.isEmpty()) {
        verifyArgs << "-s" << serial;
    }
    verifyArgs << "forward" << "--list";
    QString forwardList = runAdb(verifyArgs);

    if (forwardList.contains(QString("tcp:%1").arg(localPort))) {
        QString deviceInfo = serial.isEmpty() ? "default device" : serial;
        qDebug() << "ADB: Forward established localhost:" << localPort
                 << "→ android:" << remotePort << "device:" << deviceInfo;

        m_lastLocalPort = localPort;
        m_lastRemotePort = remotePort;
        m_wasAdbConnection = true;

        // Don't enable wireless ADB here — it runs `adb tcpip 5555` which
        // puts the USB device offline and kills the forward we just set up.
        // Wireless ADB is enabled later after the TCP connection is established.
        emit statusChanged("ADB tunnel ready — connecting...");
        return true;
    }

    emit statusChanged("ADB forward failed: " + output.trimmed());
    return false;
}

QString AdbHelper::runAdb(const QStringList& args, int timeoutMs) {
    QString adb = findAdb();
    if (adb.isEmpty()) return {};

    QProcess process;
    process.setProgram(adb);
    process.setArguments(args);
    process.start();

    if (!process.waitForFinished(timeoutMs)) {
        qWarning() << "ADB: Command timed out:" << args;
        process.kill();
        return {};
    }

    QString stdoutStr = QString::fromUtf8(process.readAllStandardOutput());
    QString stderrStr = QString::fromUtf8(process.readAllStandardError());

    if (process.exitCode() != 0 && !stderrStr.isEmpty()) {
        qWarning() << "ADB: Command failed:" << args << "error:" << stderrStr;
    }

    return stdoutStr + stderrStr;
}
