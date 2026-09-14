#pragma once
// Windows-only; compiled when ENABLE_SENDER is set.
// Do NOT wrap in #ifdef _WIN32 — AutoMoc cannot resolve preprocessor guards
// and will skip Q_OBJECT, causing linker errors.

#include <QObject>
#include <QByteArray>
#include <QRect>
#include <QQueue>
#include <QSet>
#include <cstdint>

class QTimer;
enum class InputEventType : int;

// Injects input received from a receiver into the local Windows desktop.
//
// This is the Windows counterpart of the macOS sender's InputHandler: the
// receiver reports where the user touched or clicked in normalised 0-1 coords,
// and we replay it with SendInput against the display we are streaming.
class InputInjector : public QObject {
    Q_OBJECT
public:
    explicit InputInjector(QObject* parent = nullptr);
    ~InputInjector() override;

    // Desktop rect of the streamed display, in virtual-desktop pixels.
    // Without this every event would land on the primary monitor.
    void setTargetBounds(const QRect& bounds);
    QRect targetBounds() const { return m_bounds; }

    // Resolve a display device name (e.g. "\\\\.\\DISPLAY3") to its desktop
    // rect and adopt it as the target. Returns false if the name is unknown.
    bool setTargetDisplayName(const QString& deviceName);

    // Treat ⌘ as Ctrl so Mac shortcuts (⌘C, ⌘V) do the expected thing.
    void setCommandAsControl(bool enabled) { m_commandAsControl = enabled; }

    // Feed one length-stripped InputEvent JSON packet from the receiver.
    void handlePacket(const QByteArray& json);

signals:
    void keyframeRequested();                       // Command keyCode 999
    void screenInfoReceived(int width, int height); // Command keyCode 777
    void heartbeatReceived();                       // Command keyCode 888
    void injectionBlocked(const QString& reason);   // e.g. UIPI refusal

private:
    bool isDuplicate(quint64 eventId);
    bool toAbsolute(double nx, double ny, long& ax, long& ay) const;
    bool toPixels(double nx, double ny, long& px, long& py) const;
    void injectMouse(double nx, double ny, uint32_t buttonFlags);
    void injectScroll(double nx, double ny, double deltaX, double deltaY,
                      uint16_t gestureMode);
    void injectZoomSteps(int steps);            // Ctrl+wheel, one notch per step
    void injectSwipe(uint16_t commandCode);     // three-finger swipe → Windows shortcut
    void sendChord(const uint16_t* vks, int count);
    void injectKey(uint16_t macKeyCode, bool down);
    void reportFailureOnce(const QString& reason);

    // Apple Pencil → a synthetic Windows pen, so pressure and tilt reach apps
    // that read pen input (Photoshop, Krita, OneNote, Whiteboard). Returns
    // false when no pen device can be created, and the caller falls back to
    // the mouse path the Pencil has always used.
    bool injectPen(InputEventType type, double nx, double ny,
                   double pressure, double altitude, double azimuth);
    bool ensurePenDevice();
    bool injectPenFrame(uint32_t pointerFlags);   // m_penFrame with these flags
    void refreshPenContact();                      // keep-alive while held still

    QRect m_bounds;
    bool m_commandAsControl = true;

    // Critical events are transmitted three times by the receiver (see
    // NetworkListener::sendInputEvent), so replaying every packet would turn
    // one click into a triple-click. Dedupe on eventId, as the macOS sender does.
    static constexpr int kMaxRecentEvents = 200;
    QSet<quint64> m_recentIds;
    QQueue<quint64> m_recentQueue;

    bool m_reportedFailure = false;

    // Pinch arrives as many small per-frame amounts. Each Ctrl+wheel message is
    // a whole zoom step to most apps whatever its size, so replaying every frame
    // zoomed in huge jumps. Accumulate, and zoom one notch per kPinchPerStep.
    static constexpr double kPinchPerStep = 20.0;   // ~20% scale change per notch
    double m_pinchAccum = 0.0;
    qint64 m_lastPinchMs = 0;
    bool m_smartZoomedIn = false;
    bool m_loggedRotation = false;

    // Synthetic pen. The device handle is an HSYNTHETICPOINTERDEVICE; the last
    // frame is kept as raw POINTER_TYPE_INFO bytes so this header needs no
    // Windows types.
    void* m_penDevice = nullptr;
    bool m_penUnavailable = false;
    bool m_penInRange = false;
    bool m_penInContact = false;
    QByteArray m_penFrame;
    qint64 m_lastPenFrameMs = 0;
    QTimer* m_penKeepAlive = nullptr;
};
