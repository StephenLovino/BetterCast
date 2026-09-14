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
    //
    // receiverName is the device's human-readable name. When given, the
    // virtual display created or claimed for it is remembered under that name,
    // so the same device gets the same display back next time.
    bool startSending(const QString& receiverHost, uint16_t port = 51820,
                      int fps = 30, int bitrateMbps = 8,
                      const QString& displayName = QString(),
                      int width = 0, int height = 0,
                      const QString& receiverName = QString());

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
    //
    // With a receiver name, also true when no existing virtual display is free
    // for that receiver, so one would have to be added.
    bool displaySetupPending(const QString& receiverName = QString()) const;

    // ── Virtual displays, one per receiver ─────────────────────────────────
    //
    // Each receiver that has been extended to owns a virtual display, kept by
    // its device node id. Windows itself names every one of them "VDD by MTT"
    // - the driver shares one EDID - so these names live in BetterCast.

    struct VirtualDisplayEntry {
        QString instanceId;    // ROOT\DISPLAY\000N, stable across renumbering
        QString receiverName;  // empty when no receiver has claimed it
        QString displayName;   // current \\.\DISPLAYn, empty when detached or gone
        bool present = true;   // false for a disconnected leftover
        bool inUse = false;    // a live session is capturing it
    };
    // Every node of the driver, disconnected leftovers included.
    QVector<VirtualDisplayEntry> virtualDisplays() const;

    QString virtualDisplayFor(const QString& receiverName) const;  // node id or empty
    QString receiverForNode(const QString& instanceId) const;      // name or empty
    QString receiverForDisplay(const QString& displayName) const;  // name or empty

    // Remove one receiver's virtual display and forget the assignment.
    // Refused while anything streams to a virtual display: removing a node
    // re-enumerates every monitor the driver owns.
    bool removeVirtualDisplay(const QString& instanceId);

    // Forget every receiver assignment, after all displays were removed.
    void clearDisplayAssignments();

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
        QString receiverName;   // human-readable device name, may be empty
        QString nodeId;         // VDD node behind displayName; empty when mirroring
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
    // The receiver's own display comes first; a new one is added only when no
    // existing display is free.
    QString claimDisplayFor(const QString& host, const QString& receiverName,
                            const QSize& target);

    void assignDisplay(const QString& receiverName, const QString& instanceId);
    bool nodeInUse(const QString& instanceId) const;
    bool streamingToVirtualDisplay() const;

    // After a node install re-enumerates the driver, find each live session's
    // display again by its node and restart its capture there.
    void rebindSessionsAfterReenumeration();

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
    bool m_displaysPrepared = false;   // the driver's mode list has been checked

    // There used to be a pool of three displays built before the first stream,
    // so a second or third receiver would never need a node added mid-stream.
    // With one receiver - the usual case - that was two extra device installs,
    // each blanking every screen, and two idle 800x600 monitors on the
    // desktop. Displays are now added one at a time, when a receiver needs
    // one, and live sessions are moved onto their renumbered displays.
    VirtualDisplayVDD* m_vdd = nullptr;

    // Defaults applied to the next session started without explicit values.
    int m_adapterIndex = 0;
    int m_outputIndex = 0;
    QString m_displayName;
};
