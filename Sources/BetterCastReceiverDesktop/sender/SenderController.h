#pragma once

#include <QObject>
#include <QSize>
#include <QString>
#include <QVector>
#include <cstdint>

class ScreenCapture;
class VideoEncoderFF;
class NetworkSender;
class VirtualDisplayVDD;
class InputInjector;

// Orchestrates capture → encode → send, once per connected receiver.
//
// Each receiver gets its own virtual display, capture, encoder and socket —
// matching the macOS sender, where two connected devices mean two extra
// screens rather than the same screen mirrored twice. Sessions are fully
// independent: one receiver disconnecting or failing to encode does not
// disturb the others.
class SenderController : public QObject {
    Q_OBJECT
public:
    explicit SenderController(QObject* parent = nullptr);
    ~SenderController() override;

    // Start streaming to one receiver. `displayName` selects the monitor to
    // capture (e.g. "\\\\.\\DISPLAY21"); when empty the controller claims the
    // next virtual display not already in use by another session.
    // width/height of 0 means "match the primary display".
    //
    // Naming a display the user is actually looking at means mirroring rather
    // than extending: that display is captured as-is, never resized, and never
    // swapped for a spare virtual one.
    bool startSending(const QString& receiverHost, uint16_t port = 51820,
                      int fps = 30, int bitrateMbps = 8,
                      const QString& displayName = QString(),
                      int width = 0, int height = 0);

    // Stop one receiver, or every receiver.
    void stopSending(const QString& receiverHost);
    void stopAll();

    bool isSending() const { return !m_sessions.isEmpty(); }
    bool isSendingTo(const QString& receiverHost) const;
    int  sessionCount() const { return m_sessions.size(); }
    QStringList activeReceivers() const;

    // Display used by a given receiver, for the UI to show what goes where.
    QString displayForReceiver(const QString& receiverHost) const;

    // Default monitor for the next session started without an explicit display.
    void setMonitorIndex(int adapterIndex, int outputIndex);
    void setDisplayName(const QString& name) { m_displayName = name; }

    // VDD virtual display management
    VirtualDisplayVDD* vdd() const { return m_vdd; }

    // True when the next startSending() will run the one-time display setup:
    // advertising modes restarts the driver and adding nodes re-enumerates every
    // monitor, so every screen blanks several times. Front ends ask this first
    // so they can warn before it happens instead of it looking like a crash.
    bool displaySetupPending() const;

    QString encoderInfo() const;

signals:
    void started(const QString& receiverHost);
    void stopped(const QString& receiverHost);
    void connected(const QString& receiverHost);
    void disconnected(const QString& receiverHost);
    void error(const QString& message);
    void statusChanged(const QString& status);
    // Emitted whenever a session starts or ends, so the UI can refresh counts.
    void sessionsChanged();

private:
    // One receiver's pipeline. Owned by the controller; torn down as a unit.
    struct Session {
        QString host;
        uint16_t port = 51820;
        QString displayName;
        int adapterIndex = 0;
        int outputIndex = 0;
        int fps = 30;
        int bitrateMbps = 8;
        int width = 0;          // 0 = match the primary display
        int height = 0;
        bool encoderReady = false;

        ScreenCapture* capture = nullptr;
        VideoEncoderFF* encoder = nullptr;
        NetworkSender* network = nullptr;
        InputInjector* input = nullptr;
    };

    Session* findSession(const QString& host) const;
    void destroySession(Session* s);
    // Whether a display is one of the driver's, as opposed to a monitor the
    // user is actually looking at. Naming a real monitor is a mirror request
    // and has to be treated differently — see startSending.
    bool isVirtualDisplay(const QString& displayName) const;
    // Choose a virtual display no other session is streaming, creating one if
    // none is free. Returns an empty string when nothing suitable exists.
    // `target` is the size the stream wants, so a detached display is attached
    // at it in one display change instead of attached and then resized.
    QString claimDisplayFor(const QString& host, const QSize& target);

    // One-time display-driver setup, run on the first send while nothing is
    // streaming. Safe to call repeatedly.
    void prepareDisplays();
    // Every size the driver must advertise before displays can run at it.
    static QVector<QSize> setupModes();
    bool displayInUse(const QString& displayName) const;

    void onFrameCaptured(Session* s, const QByteArray& nv12, int width, int height,
                         qint64 ptsNanos);
    void onEncoded(Session* s, const QByteArray& payload);
    void onSessionConnected(Session* s);
    void onSessionDisconnected(Session* s);

    QVector<Session*> m_sessions;
    // Auto-adding a display raises a UAC prompt. If it fails once it will keep
    // failing for the same reason, so stop trying and let the user decide -
    // five prompts in a row was the observed behaviour otherwise.
    bool m_autoAddFailed = false;
    bool m_displaysPrepared = false;
    int  m_desiredPoolSize = 0;   // set from kDisplayPoolSize, grows on demand

    // How many virtual displays to have ready before the first stream starts.
    // Growing the pool later restarts the driver and kills any live capture, so
    // it is built once, up front, big enough for the usual phone + tablet +
    // laptop case.
    static constexpr int kDisplayPoolSize = 3;
    VirtualDisplayVDD* m_vdd = nullptr;

    // Defaults applied to the next session started without explicit values.
    int m_adapterIndex = 0;
    int m_outputIndex = 0;
    QString m_displayName;
};
