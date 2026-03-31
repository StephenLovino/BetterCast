#pragma once

#include <QObject>
#include <QString>
#include <cstdint>

class ScreenCapture;
class VideoEncoderFF;
class NetworkSender;
class VirtualDisplayVDD;

// Orchestrates screen capture → encode → send pipeline.
// Manages lifecycle and wiring between components.
// Optionally creates a virtual display via VDD before streaming.
class SenderController : public QObject {
    Q_OBJECT
public:
    explicit SenderController(QObject* parent = nullptr);
    ~SenderController() override;

    // Start sender mode: capture screen, encode, and stream to receiver
    bool startSending(const QString& receiverHost, uint16_t port = 51820,
                      int fps = 30, int bitrateMbps = 8);
    void stopSending();
    bool isSending() const { return m_sending; }

    // Monitor selection (adapter + output index from DXGI enumeration)
    void setMonitorIndex(int adapterIndex, int outputIndex);

    // VDD virtual display management
    VirtualDisplayVDD* vdd() const { return m_vdd; }

    QString encoderInfo() const;

signals:
    void started();
    void stopped();
    void connected();
    void disconnected();
    void error(const QString& message);
    void statusChanged(const QString& status);

private slots:
    void onFrameCaptured(const QByteArray& nv12, int width, int height);
    void onEncoded(const QByteArray& payload);
    void onConnected();
    void onDisconnected();

private:
    ScreenCapture* m_capture = nullptr;
    VideoEncoderFF* m_encoder = nullptr;
    NetworkSender* m_network = nullptr;
    VirtualDisplayVDD* m_vdd = nullptr;
    bool m_sending = false;
    bool m_encoderReady = false;
    int m_fps = 30;
    int m_bitrateMbps = 8;
    int m_adapterIndex = 0;
    int m_outputIndex = 0;
};
