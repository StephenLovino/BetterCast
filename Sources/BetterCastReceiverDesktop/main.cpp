#include <QApplication>
#include <QSurfaceFormat>
#include "MainWindow.h"

int main(int argc, char* argv[]) {
    // Request OpenGL 3.0+ for texture support
    QSurfaceFormat format;
    format.setVersion(3, 0);
    format.setProfile(QSurfaceFormat::CoreProfile);
    format.setSwapInterval(1); // VSync
    QSurfaceFormat::setDefaultFormat(format);

    QApplication app(argc, argv);
    app.setApplicationName("BetterCast Receiver");
    app.setOrganizationName("BetterCast");
    app.setApplicationVersion("1.0.0");

    MainWindow window;
    window.show();

    return app.exec();
}
