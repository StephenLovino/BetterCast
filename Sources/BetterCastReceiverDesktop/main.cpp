#include <QApplication>
#include <QSurfaceFormat>
#include <QIcon>
#include <QProcess>
#include <QStandardPaths>
#include <QFile>
#include <QDebug>
#include "MainWindow.h"

#ifdef _WIN32
// Add Windows Firewall exception for mDNS multicast (needed for auto-discovery)
static void ensureFirewallRule() {
    // Check if our firewall rule already exists
    QProcess check;
    check.start("netsh", {"advfirewall", "firewall", "show", "rule", "name=BetterCast mDNS"});
    check.waitForFinished(3000);
    QString output = QString::fromUtf8(check.readAllStandardOutput());
    if (output.contains("BetterCast mDNS")) return; // Already exists

    // Try to add inbound UDP rule for mDNS port 5353
    // This requires admin, so it may fail silently — that's OK
    QProcess add;
    add.start("netsh", {"advfirewall", "firewall", "add", "rule",
                         "name=BetterCast mDNS",
                         "dir=in", "action=allow", "protocol=UDP",
                         "localport=5353",
                         "profile=private,public",
                         "description=Allow mDNS for BetterCast auto-discovery"});
    add.waitForFinished(3000);
    if (add.exitCode() == 0) {
        qDebug() << "Firewall: Added mDNS rule for auto-discovery";
    } else {
        qDebug() << "Firewall: Could not add mDNS rule (needs admin) — manual IP still works";
    }

    // Also add rule for the app itself on TCP 51820
    QProcess addTcp;
    addTcp.start("netsh", {"advfirewall", "firewall", "add", "rule",
                            "name=BetterCast Receiver",
                            "dir=in", "action=allow", "protocol=TCP",
                            "localport=51820",
                            "profile=private,public",
                            "description=Allow BetterCast screen streaming"});
    addTcp.waitForFinished(3000);
}
#endif

int main(int argc, char* argv[]) {
    // Use Compatibility Profile for GL_LUMINANCE/GL_LUMINANCE_ALPHA support
    // Core Profile removes these, breaking NV12 texture uploads on Windows
    QSurfaceFormat format;
    format.setVersion(2, 1);
    format.setProfile(QSurfaceFormat::CompatibilityProfile);
    format.setSwapInterval(1); // VSync
    QSurfaceFormat::setDefaultFormat(format);

    QApplication app(argc, argv);
    app.setApplicationName("BetterCast");
    app.setOrganizationName("BetterCast");
    app.setApplicationVersion("1.0.0");
    app.setWindowIcon(QIcon(":/appicon.png"));

#ifdef _WIN32
    ensureFirewallRule();
#endif

    MainWindow window;
    window.show();

    return app.exec();
}
