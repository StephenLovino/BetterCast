#include "InputInjector.h"
#include "../InputEvent.h"
#include "../KeyCodeMap.h"
#include "../LogManager.h"

#include <QDateTime>
#include <QJsonDocument>
#include <QJsonObject>
#include <QTimer>
#include <QtMath>
#include <Windows.h>
#include <cstring>

#pragma comment(lib, "user32.lib")

namespace {

qint64 nowMs() { return QDateTime::currentMSecsSinceEpoch(); }

// ─── Synthetic pointer API (Windows 10 1809+) ─────────────────────────────────
//
// CreateSyntheticPointerDevice / InjectSyntheticPointerInput are looked up in
// user32 at run time rather than taken from the SDK headers. The headers only
// declare them when NTDDI_VERSION is RS5 or later, which depends on whatever
// Qt or the build happened to define first; and looking them up means an older
// Windows gets a Pencil that still works as a mouse instead of an exe that will
// not start.

// Same layout as POINTER_TYPE_INFO, which is declared under the same RS5 guard.
struct PointerTypeInfo {
    POINTER_INPUT_TYPE type;
    union {
        POINTER_TOUCH_INFO touchInfo;
        POINTER_PEN_INFO penInfo;
    };
};

using CreateSyntheticPointerDeviceFn  = HANDLE (WINAPI*)(POINTER_INPUT_TYPE, ULONG, int);
using InjectSyntheticPointerInputFn   = BOOL (WINAPI*)(HANDLE, const PointerTypeInfo*, UINT32);
using DestroySyntheticPointerDeviceFn = void (WINAPI*)(HANDLE);

struct SyntheticPointerApi {
    CreateSyntheticPointerDeviceFn create = nullptr;
    InjectSyntheticPointerInputFn inject = nullptr;
    DestroySyntheticPointerDeviceFn destroy = nullptr;
    bool available() const { return create && inject && destroy; }
};

const SyntheticPointerApi& syntheticPointerApi() {
    static const SyntheticPointerApi api = [] {
        SyntheticPointerApi a;
        if (HMODULE user32 = GetModuleHandleW(L"user32.dll")) {
            a.create = reinterpret_cast<CreateSyntheticPointerDeviceFn>(
                reinterpret_cast<void*>(GetProcAddress(user32, "CreateSyntheticPointerDevice")));
            a.inject = reinterpret_cast<InjectSyntheticPointerInputFn>(
                reinterpret_cast<void*>(GetProcAddress(user32, "InjectSyntheticPointerInput")));
            a.destroy = reinterpret_cast<DestroySyntheticPointerDeviceFn>(
                reinterpret_cast<void*>(GetProcAddress(user32, "DestroySyntheticPointerDevice")));
        }
        return a;
    }();
    return api;
}

constexpr int kPointerFeedbackDefault = 1;   // POINTER_FEEDBACK_DEFAULT
constexpr qint64 kPinchIdleResetMs = 400;    // a new pinch starts from zero
constexpr int kPenKeepAliveMs = 100;

} // namespace

InputInjector::InputInjector(QObject* parent)
    : QObject(parent)
{
}

InputInjector::~InputInjector() {
    if (m_penDevice) {
        // Never leave Windows believing a pen is pressed on the glass.
        if (m_penInContact) injectPenFrame(POINTER_FLAG_INRANGE | POINTER_FLAG_UP);
        if (m_penInRange)   injectPenFrame(POINTER_FLAG_UPDATE);
        syntheticPointerApi().destroy(static_cast<HANDLE>(m_penDevice));
        m_penDevice = nullptr;
    }
}

void InputInjector::setTargetBounds(const QRect& bounds) {
    if (bounds.isValid() && !bounds.isEmpty()) {
        m_bounds = bounds;
        LogManager::instance().log(
            QString("Input: Target display bounds %1,%2 %3x%4")
                .arg(bounds.x()).arg(bounds.y()).arg(bounds.width()).arg(bounds.height()));
    }
}

bool InputInjector::setTargetDisplayName(const QString& deviceName) {
    if (deviceName.isEmpty()) return false;

    DEVMODEW dm = {};
    dm.dmSize = sizeof(dm);
    if (!EnumDisplaySettingsW(reinterpret_cast<LPCWSTR>(deviceName.utf16()),
                              ENUM_CURRENT_SETTINGS, &dm)) {
        LogManager::instance().log("Input: Could not resolve bounds for " + deviceName);
        return false;
    }

    setTargetBounds(QRect(dm.dmPosition.x, dm.dmPosition.y,
                          static_cast<int>(dm.dmPelsWidth),
                          static_cast<int>(dm.dmPelsHeight)));
    return true;
}

bool InputInjector::isDuplicate(quint64 eventId) {
    if (eventId == 0) return false;               // unset id — cannot dedupe
    if (m_recentIds.contains(eventId)) return true;

    m_recentIds.insert(eventId);
    m_recentQueue.enqueue(eventId);
    if (m_recentQueue.size() > kMaxRecentEvents) {
        m_recentIds.remove(m_recentQueue.dequeue());
    }
    return false;
}

// Map a normalised point on the streamed display to SendInput's absolute
// coordinate space: 0..65535 spanning the whole virtual desktop.
bool InputInjector::toAbsolute(double nx, double ny, long& ax, long& ay) const {
    if (!m_bounds.isValid() || m_bounds.isEmpty()) return false;

    const int vx = GetSystemMetrics(SM_XVIRTUALSCREEN);
    const int vy = GetSystemMetrics(SM_YVIRTUALSCREEN);
    const int vw = GetSystemMetrics(SM_CXVIRTUALSCREEN);
    const int vh = GetSystemMetrics(SM_CYVIRTUALSCREEN);
    if (vw <= 1 || vh <= 1) return false;

    nx = qBound(0.0, nx, 1.0);
    ny = qBound(0.0, ny, 1.0);

    const double px = m_bounds.x() + nx * m_bounds.width();
    const double py = m_bounds.y() + ny * m_bounds.height();

    // MOUSEEVENTF_VIRTUALDESK normalises against the virtual desktop, whose
    // origin can be negative when a monitor sits left of or above the primary.
    ax = qRound((px - vx) * 65535.0 / (vw - 1));
    ay = qRound((py - vy) * 65535.0 / (vh - 1));
    return true;
}

// The same point in desktop pixels, which is what pointer injection takes.
bool InputInjector::toPixels(double nx, double ny, long& px, long& py) const {
    if (!m_bounds.isValid() || m_bounds.isEmpty()) return false;
    nx = qBound(0.0, nx, 1.0);
    ny = qBound(0.0, ny, 1.0);
    px = m_bounds.x() + qMin(m_bounds.width() - 1, qRound(nx * m_bounds.width()));
    py = m_bounds.y() + qMin(m_bounds.height() - 1, qRound(ny * m_bounds.height()));
    return true;
}

void InputInjector::reportFailureOnce(const QString& reason) {
    if (m_reportedFailure) return;
    m_reportedFailure = true;
    LogManager::instance().log("Input: " + reason);
    emit injectionBlocked(reason);
}

void InputInjector::injectMouse(double nx, double ny, uint32_t buttonFlags) {
    long ax = 0, ay = 0;
    if (!toAbsolute(nx, ny, ax, ay)) return;

    INPUT in = {};
    in.type = INPUT_MOUSE;
    in.mi.dx = ax;
    in.mi.dy = ay;
    in.mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK
                    | buttonFlags;

    if (SendInput(1, &in, sizeof(INPUT)) == 0) {
        reportFailureOnce(
            QString("SendInput refused (error %1). Input cannot reach elevated "
                    "windows unless BetterCast also runs as administrator.")
                .arg(GetLastError()));
    }
}

void InputInjector::injectScroll(double nx, double ny, double deltaX, double deltaY,
                                 uint16_t gestureMode) {
    // Windows delivers wheel messages to whatever is under the pointer, so the
    // pointer is parked where the gesture happened - but only when the
    // receiver said where that was. The iOS, Mac and Qt receivers send scroll
    // and pinch with no position at all, which reads as (0, 0); moving there
    // put the pointer in the display's top-left corner and scrolled whatever
    // window sat under it instead of the one being looked at. With no position
    // the pointer stays where the last tap or move left it. Android does send
    // the pinch focus and the two-finger midpoint, so those still move it.
    const bool havePosition = !(nx == 0.0 && ny == 0.0);
    if (havePosition) injectMouse(nx, ny, 0);

    switch (gestureMode) {
    case kGesturePinch: {
        const qint64 now = nowMs();
        if (now - m_lastPinchMs > kPinchIdleResetMs) m_pinchAccum = 0.0;
        m_lastPinchMs = now;
        m_pinchAccum += deltaY;
        int steps = 0;
        while (m_pinchAccum >= kPinchPerStep)  { steps++; m_pinchAccum -= kPinchPerStep; }
        while (m_pinchAccum <= -kPinchPerStep) { steps--; m_pinchAccum += kPinchPerStep; }
        if (steps != 0) injectZoomSteps(steps);
        return;
    }
    case kGestureSmartZoom:
        // Two-finger double tap. It arrives with no amount, which used to send
        // Ctrl+wheel by zero and do nothing. Toggle in and back out instead,
        // the way smart zoom does on a Mac.
        m_smartZoomedIn = !m_smartZoomedIn;
        injectZoomSteps(m_smartZoomedIn ? 2 : -2);
        return;
    case kGestureRotate:
        // Windows has no rotate input for a mouse or keyboard to send. This
        // used to fall through as a sideways scroll, which nudged content left
        // and right whenever two fingers twisted. Ignore it.
        if (!m_loggedRotation) {
            m_loggedRotation = true;
            LogManager::instance().log("Input: Rotation gestures have no Windows "
                                       "equivalent and are ignored");
        }
        return;
    default:
        break;
    }

    INPUT in[2] = {};
    int count = 0;
    if (deltaY != 0.0) {
        in[count].type = INPUT_MOUSE;
        in[count].mi.dwFlags = MOUSEEVENTF_WHEEL;
        in[count].mi.mouseData = static_cast<DWORD>(qRound(deltaY * WHEEL_DELTA / 10.0));
        count++;
    }
    if (deltaX != 0.0) {
        in[count].type = INPUT_MOUSE;
        in[count].mi.dwFlags = MOUSEEVENTF_HWHEEL;
        in[count].mi.mouseData = static_cast<DWORD>(qRound(deltaX * WHEEL_DELTA / 10.0));
        count++;
    }
    if (count > 0 && SendInput(count, in, sizeof(INPUT)) == 0) {
        reportFailureOnce(QString("SendInput refused (error %1)").arg(GetLastError()));
    }
}

// Ctrl+wheel is the Windows zoom idiom (macOS uses ⌘+wheel). One whole notch
// per step: browsers, Office and Explorer all treat each message as one step.
void InputInjector::injectZoomSteps(int steps) {
    if (steps == 0) return;
    INPUT seq[3] = {};
    seq[0].type = INPUT_KEYBOARD;
    seq[0].ki.wVk = VK_CONTROL;

    seq[1].type = INPUT_MOUSE;
    seq[1].mi.dwFlags = MOUSEEVENTF_WHEEL;
    seq[1].mi.mouseData = static_cast<DWORD>(steps * WHEEL_DELTA);

    seq[2].type = INPUT_KEYBOARD;
    seq[2].ki.wVk = VK_CONTROL;
    seq[2].ki.dwFlags = KEYEVENTF_KEYUP;

    if (SendInput(3, seq, sizeof(INPUT)) == 0) {
        reportFailureOnce(QString("SendInput refused (error %1)").arg(GetLastError()));
    }
}

// Press every key in order, then release them in reverse.
void InputInjector::sendChord(const uint16_t* vks, int count) {
    constexpr int kMaxKeys = 4;
    if (count <= 0 || count > kMaxKeys) return;
    INPUT seq[kMaxKeys * 2] = {};
    for (int i = 0; i < count; i++) {
        const uint16_t vk = vks[i];
        const bool extended = KeyCodeMap::isExtendedVk(vk) || vk == VK_LWIN;
        INPUT& down = seq[i];
        down.type = INPUT_KEYBOARD;
        down.ki.wVk = vk;
        down.ki.wScan = static_cast<WORD>(MapVirtualKeyW(vk, MAPVK_VK_TO_VSC));
        down.ki.dwFlags = extended ? KEYEVENTF_EXTENDEDKEY : 0;

        INPUT& up = seq[count * 2 - 1 - i];
        up = down;
        up.ki.dwFlags |= KEYEVENTF_KEYUP;
    }
    if (SendInput(static_cast<UINT>(count * 2), seq, sizeof(INPUT)) == 0) {
        reportFailureOnce(QString("SendInput refused (error %1)").arg(GetLastError()));
    }
}

// Three-finger swipes, mapped to what the same swipe does on a Windows
// precision touchpad and to the nearest thing to the Mac sender's Ctrl+Arrow:
// up opens Task View (Mission Control), down shows the desktop (App Exposé
// has no Windows twin), left and right move between virtual desktops (spaces).
// These used to hit `default: break` and do nothing.
void InputInjector::injectSwipe(uint16_t commandCode) {
    switch (commandCode) {
    case kSwipeUpKeyCode: {
        const uint16_t keys[] = {VK_LWIN, VK_TAB};
        LogManager::instance().log("Input: Three-finger swipe up → Task View (Win+Tab)");
        sendChord(keys, 2);
        break;
    }
    case kSwipeDownKeyCode: {
        const uint16_t keys[] = {VK_LWIN, 'D'};
        LogManager::instance().log("Input: Three-finger swipe down → Show desktop (Win+D)");
        sendChord(keys, 2);
        break;
    }
    case kSwipeLeftKeyCode: {
        const uint16_t keys[] = {VK_LWIN, VK_CONTROL, VK_LEFT};
        LogManager::instance().log("Input: Three-finger swipe → previous desktop (Win+Ctrl+Left)");
        sendChord(keys, 3);
        break;
    }
    case kSwipeRightKeyCode: {
        const uint16_t keys[] = {VK_LWIN, VK_CONTROL, VK_RIGHT};
        LogManager::instance().log("Input: Three-finger swipe → next desktop (Win+Ctrl+Right)");
        sendChord(keys, 3);
        break;
    }
    default:
        break;
    }
}

// ─── Apple Pencil → Windows pen ───────────────────────────────────────────────

bool InputInjector::ensurePenDevice() {
    if (m_penDevice) return true;
    if (m_penUnavailable) return false;

    const auto& api = syntheticPointerApi();
    if (!api.available()) {
        m_penUnavailable = true;
        LogManager::instance().log("Input: This Windows has no synthetic pen API (needs "
                                   "Windows 10 1809 or later) — Apple Pencil works as a "
                                   "mouse, without pressure or tilt");
        return false;
    }
    HANDLE device = api.create(PT_PEN, 1, kPointerFeedbackDefault);
    if (!device) {
        m_penUnavailable = true;
        LogManager::instance().log(
            QString("Input: Could not create a synthetic pen (error %1) — Apple Pencil "
                    "works as a mouse, without pressure or tilt").arg(GetLastError()));
        return false;
    }
    m_penDevice = device;
    m_penFrame = QByteArray(static_cast<int>(sizeof(PointerTypeInfo)), '\0');
    LogManager::instance().log("Input: Apple Pencil detected — injecting it as a Windows "
                               "pen with pressure and tilt");
    return true;
}

bool InputInjector::injectPenFrame(uint32_t pointerFlags) {
    if (!m_penDevice || m_penFrame.size() != static_cast<int>(sizeof(PointerTypeInfo))) {
        return false;
    }
    PointerTypeInfo info;
    std::memcpy(&info, m_penFrame.constData(), sizeof(info));
    info.penInfo.pointerInfo.pointerFlags = pointerFlags;
    if (!(pointerFlags & POINTER_FLAG_INCONTACT)) info.penInfo.pressure = 0;

    if (!syntheticPointerApi().inject(static_cast<HANDLE>(m_penDevice), &info, 1)) {
        reportFailureOnce(
            QString("Pen injection refused (error %1). Pen input cannot reach elevated "
                    "windows unless BetterCast also runs as administrator.")
                .arg(GetLastError()));
        return false;
    }
    m_lastPenFrameMs = nowMs();
    return true;
}

// A pen held still on the glass sends nothing, and Windows cancels an injected
// contact that goes quiet. Repeat the last frame so a held stroke stays down.
void InputInjector::refreshPenContact() {
    if (!m_penInContact) {
        if (m_penKeepAlive) m_penKeepAlive->stop();
        return;
    }
    if (nowMs() - m_lastPenFrameMs >= kPenKeepAliveMs - 10) {
        injectPenFrame(POINTER_FLAG_INRANGE | POINTER_FLAG_INCONTACT | POINTER_FLAG_UPDATE);
    }
}

bool InputInjector::injectPen(InputEventType type, double nx, double ny,
                              double pressure, double altitude, double azimuth) {
    if (!ensurePenDevice()) return false;

    long px = 0, py = 0;
    if (!toPixels(nx, ny, px, py)) return true;   // no target yet; nothing to do

    PointerTypeInfo info;
    std::memset(&info, 0, sizeof(info));
    info.type = PT_PEN;
    POINTER_PEN_INFO& pen = info.penInfo;
    pen.pointerInfo.pointerType = PT_PEN;
    pen.pointerInfo.pointerId = 0;
    pen.pointerInfo.ptPixelLocation.x = px;
    pen.pointerInfo.ptPixelLocation.y = py;
    pen.penFlags = PEN_FLAG_NONE;
    pen.penMask = PEN_MASK_PRESSURE | PEN_MASK_TILT_X | PEN_MASK_TILT_Y;
    // Windows pressure runs 0-1024. A pen in contact never reports 0, or apps
    // read the stroke as not touching.
    pen.pressure = static_cast<UINT32>(qBound(1, qRound(pressure * 1024.0), 1024));

    // Tilt: iOS gives altitude (π/2 upright) and azimuth (direction of lean in
    // view coordinates, y down). Windows wants the lean in degrees projected on
    // each screen axis, -90..90, positive towards +x and towards the user (+y).
    const double lean = qBound(0.0, 90.0 - qRadiansToDegrees(altitude), 90.0);
    pen.tiltX = qBound(-90, qRound(lean * qCos(azimuth)), 90);
    pen.tiltY = qBound(-90, qRound(lean * qSin(azimuth)), 90);

    std::memcpy(m_penFrame.data(), &info, sizeof(info));

    if (!m_penKeepAlive) {
        m_penKeepAlive = new QTimer(this);
        m_penKeepAlive->setInterval(kPenKeepAliveMs);
        connect(m_penKeepAlive, &QTimer::timeout, this, &InputInjector::refreshPenContact);
    }

    // Windows expects a pen to come into range before it touches down.
    if (!m_penInRange && type != InputEventType::LeftMouseUp) {
        if (!injectPenFrame(POINTER_FLAG_INRANGE | POINTER_FLAG_UPDATE)) return false;
        m_penInRange = true;
    }

    switch (type) {
    case InputEventType::LeftMouseDown:
        if (!injectPenFrame(POINTER_FLAG_INRANGE | POINTER_FLAG_INCONTACT | POINTER_FLAG_DOWN)) {
            return false;
        }
        m_penInContact = true;
        m_penKeepAlive->start();
        break;
    case InputEventType::MouseMove:
        if (m_penInContact) {
            injectPenFrame(POINTER_FLAG_INRANGE | POINTER_FLAG_INCONTACT | POINTER_FLAG_UPDATE);
        } else {
            injectPenFrame(POINTER_FLAG_INRANGE | POINTER_FLAG_UPDATE);   // hovering
        }
        break;
    case InputEventType::LeftMouseUp:
        // The receiver sends no hover, so a lift is also the pen leaving range.
        if (m_penInContact) injectPenFrame(POINTER_FLAG_INRANGE | POINTER_FLAG_UP);
        if (m_penInRange || m_penInContact) injectPenFrame(POINTER_FLAG_UPDATE);
        m_penInContact = false;
        m_penInRange = false;
        m_penKeepAlive->stop();
        break;
    default:
        return false;
    }
    return true;
}

void InputInjector::injectKey(uint16_t macKeyCode, bool down) {
    const uint16_t vk = KeyCodeMap::macToVk(macKeyCode, m_commandAsControl);
    if (vk == 0) {
        LogManager::instance().log(
            QString("Input: Unmapped mac key code 0x%1").arg(macKeyCode, 0, 16));
        return;
    }

    INPUT in = {};
    in.type = INPUT_KEYBOARD;
    in.ki.wVk = vk;
    // Supply the scan code too — some games and remote-desktop stacks read it
    // in preference to the virtual key.
    in.ki.wScan = static_cast<WORD>(MapVirtualKeyW(vk, MAPVK_VK_TO_VSC));
    in.ki.dwFlags = 0;
    if (KeyCodeMap::isExtendedVk(vk)) in.ki.dwFlags |= KEYEVENTF_EXTENDEDKEY;
    if (!down)                        in.ki.dwFlags |= KEYEVENTF_KEYUP;

    if (SendInput(1, &in, sizeof(INPUT)) == 0) {
        reportFailureOnce(QString("SendInput refused (error %1)").arg(GetLastError()));
    }
}

void InputInjector::handlePacket(const QByteArray& json) {
    QJsonParseError err{};
    const QJsonDocument doc = QJsonDocument::fromJson(json, &err);
    if (err.error != QJsonParseError::NoError || !doc.isObject()) return;

    const QJsonObject obj = doc.object();
    const auto type = static_cast<InputEventType>(obj.value("type").toInt());
    const double x = obj.value("x").toDouble();
    const double y = obj.value("y").toDouble();
    const auto keyCode = static_cast<uint16_t>(obj.value("keyCode").toInt());
    const double deltaX = obj.value("deltaX").toDouble();
    const double deltaY = obj.value("deltaY").toDouble();
    const auto eventId = static_cast<quint64>(obj.value("eventId").toVariant().toULongLong());

    // Commands are control-plane, not input — handle before the dedupe so a
    // repeated keyframe request is never swallowed.
    if (type == InputEventType::Command) {
        switch (keyCode) {
            case kHeartbeatKeyCode:  emit heartbeatReceived(); break;
            case kIDRRequestKeyCode: emit keyframeRequested(); break;
            case kScreenInfoKeyCode: emit screenInfoReceived(static_cast<int>(deltaX),
                                                             static_cast<int>(deltaY)); break;
            case kSwipeUpKeyCode:
            case kSwipeDownKeyCode:
            case kSwipeLeftKeyCode:
            case kSwipeRightKeyCode:
                // Swipes, unlike keyframe requests, must act once: the
                // receiver sends each one three times.
                if (!isDuplicate(eventId)) injectSwipe(keyCode);
                break;
            default: break;
        }
        return;
    }

    if (isDuplicate(eventId)) return;

    // Apple Pencil (iOS receiver v19+): a stylus event is an ordinary mouse
    // event that also carries pressure. A finger never sends pressure, which is
    // what keeps it a plain click. The lift carries pressure 0.
    const QJsonValue pressureValue = obj.value("pressure");
    if (pressureValue.isDouble() &&
        (type == InputEventType::MouseMove || type == InputEventType::LeftMouseDown ||
         type == InputEventType::LeftMouseUp)) {
        const double altitude = obj.value("altitude").toDouble(M_PI / 2.0);
        const double azimuth = obj.value("azimuth").toDouble(0.0);
        if (injectPen(type, x, y, pressureValue.toDouble(), altitude, azimuth)) return;
        // No pen device on this Windows: fall through to the mouse path below.
    }

    switch (type) {
        case InputEventType::MouseMove:
            injectMouse(x, y, 0);
            break;
        case InputEventType::LeftMouseDown:
            injectMouse(x, y, MOUSEEVENTF_LEFTDOWN);
            break;
        case InputEventType::LeftMouseUp:
            injectMouse(x, y, MOUSEEVENTF_LEFTUP);
            break;
        case InputEventType::RightMouseDown:
            injectMouse(x, y, MOUSEEVENTF_RIGHTDOWN);
            break;
        case InputEventType::RightMouseUp:
            injectMouse(x, y, MOUSEEVENTF_RIGHTUP);
            break;
        case InputEventType::ScrollWheel:
            injectScroll(x, y, deltaX, deltaY, keyCode);
            break;
        case InputEventType::KeyDown:
            injectKey(keyCode, true);
            break;
        case InputEventType::KeyUp:
            injectKey(keyCode, false);
            break;
        default:
            break;
    }
}
