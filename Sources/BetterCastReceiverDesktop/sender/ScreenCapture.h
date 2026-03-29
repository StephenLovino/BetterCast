#pragma once
#include <QObject>
#include <QByteArray>
#include <QSize>

// Abstract screen capture interface.
// Platform implementations: ScreenCaptureWin (DXGI), ScreenCaptureLinux (PipeWire)
class ScreenCapture : public QObject {
    Q_OBJECT
public:
    explicit ScreenCapture(QObject* parent = nullptr) : QObject(parent) {}
    virtual ~ScreenCapture() = default;

    virtual bool start() = 0;
    virtual void stop() = 0;
    virtual bool isRunning() const = 0;
    virtual QSize resolution() const = 0;

signals:
    // Emitted for each captured frame.
    // data: NV12 pixel buffer (Y plane followed by interleaved UV plane)
    // width, height: frame dimensions
    void frameCaptured(const QByteArray& data, int width, int height);
    void error(const QString& message);
};
