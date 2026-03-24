#include <QApplication>
#include <QSurfaceFormat>
#include <QIcon>
#include "MainWindow.h"

int main(int argc, char* argv[]) {
    // Use Compatibility Profile for GL_LUMINANCE/GL_LUMINANCE_ALPHA support
    // Core Profile removes these, breaking NV12 texture uploads on Windows
    QSurfaceFormat format;
    format.setVersion(2, 1);
    format.setProfile(QSurfaceFormat::CompatibilityProfile);
    format.setSwapInterval(1); // VSync
    QSurfaceFormat::setDefaultFormat(format);

    QApplication app(argc, argv);
    app.setApplicationName("BetterCast Receiver");
    app.setOrganizationName("BetterCast");
    app.setApplicationVersion("1.0.0");
    app.setWindowIcon(QIcon(":/appicon.png"));

    MainWindow window;
    window.show();

    return app.exec();
}
