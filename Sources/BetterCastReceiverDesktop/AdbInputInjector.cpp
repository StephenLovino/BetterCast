#include "AdbInputInjector.h"
#include "LogManager.h"

#include <QDateTime>
#include <QProcess>
#include <QtMath>

#include <algorithm>
#include <cmath>

namespace {
qint64 nowMs() { return QDateTime::currentMSecsSinceEpoch(); }

constexpr int kTapSlopPx = 16;          // phone pixels a tap may wander
constexpr qint64 kLongPressMs = 500;
constexpr qint64 kScrollThrottleMs = 120;
constexpr int kMinSwipeMs = 80;
constexpr int kMaxSwipeMs = 3000;
} // namespace

AdbInputInjector::AdbInputInjector(const QString& adbPath, const QString& serial,
                                   QSize phoneScreen, QObject* parent)
    : QObject(parent), m_adbPath(adbPath), m_serial(serial), m_phoneScreen(phoneScreen)
{
    if (!m_phoneScreen.isValid() || m_phoneScreen.isEmpty()) {
        m_phoneScreen = QSize(1080, 2400);   // same fallback as the macOS receiver
    }
    LogManager::instance().log(
        QString("ADB input: controlling %1 (%2x%3)")
            .arg(m_serial.isEmpty() ? QStringLiteral("the connected phone") : m_serial)
            .arg(m_phoneScreen.width()).arg(m_phoneScreen.height()));
}

AdbInputInjector::~AdbInputInjector() {
    if (m_shell) {
        m_shell->closeWriteChannel();
        if (!m_shell->waitForFinished(500)) m_shell->kill();
    }
}

void AdbInputInjector::setStreamSize(int width, int height) {
    if (width > 0 && height > 0) m_streamSize = QSize(width, height);
}

bool AdbInputInjector::ensureShell() {
    if (m_shell && m_shell->state() == QProcess::Running) return true;
    if (m_adbPath.isEmpty()) return false;

    if (m_shell) {
        m_shell->deleteLater();
        m_shell = nullptr;
    }
    m_shell = new QProcess(this);
    m_shell->setProcessChannelMode(QProcess::MergedChannels);
    // Nothing reads the shell's output; drain it so its pipe never fills and
    // stalls the commands behind it.
    connect(m_shell, &QProcess::readyReadStandardOutput, m_shell,
            [shell = m_shell]() { shell->readAllStandardOutput(); });

    QStringList args;
    if (!m_serial.isEmpty()) args << "-s" << m_serial;
    args << "shell";
    m_shell->start(m_adbPath, args);
    if (!m_shell->waitForStarted(3000)) {
        LogManager::instance().log("ADB input: could not start adb shell - " +
                                   m_shell->errorString());
        return false;
    }
    return true;
}

void AdbInputInjector::send(const QString& command) {
    if (!ensureShell()) return;
    m_shell->write((command + QLatin1Char('\n')).toUtf8());
}

QPoint AdbInputInjector::toPhone(double nx, double ny) const {
    int w = m_phoneScreen.width();
    int h = m_phoneScreen.height();
    // wm size reports the portrait size. A landscape stream means the phone is
    // turned, and `input` takes coordinates in the current orientation.
    const bool streamLandscape = m_streamSize.isValid() && m_streamSize.width() > m_streamSize.height();
    if (streamLandscape != (w > h)) std::swap(w, h);

    nx = qBound(0.0, nx, 1.0);
    ny = qBound(0.0, ny, 1.0);
    return QPoint(qMin(w - 1, qRound(nx * w)), qMin(h - 1, qRound(ny * h)));
}

void AdbInputInjector::inject(const InputEvent& event) {
    switch (event.type) {
    case InputEventType::LeftMouseDown: {
        m_pressed = true;
        m_pressAt = toPhone(event.x, event.y);
        m_lastPoint = m_pressAt;
        m_pressMs = nowMs();
        break;
    }
    case InputEventType::MouseMove:
        if (m_pressed) m_lastPoint = toPhone(event.x, event.y);
        break;
    case InputEventType::LeftMouseUp: {
        if (!m_pressed) break;
        m_pressed = false;
        const QPoint end = toPhone(event.x, event.y);
        const qint64 held = nowMs() - m_pressMs;
        const int moved = (end - m_pressAt).manhattanLength();
        if (moved <= kTapSlopPx && held < kLongPressMs) {
            send(QString("input tap %1 %2").arg(m_pressAt.x()).arg(m_pressAt.y()));
        } else {
            // A drag replays as one swipe over the time it took, so a slow drag
            // stays slow; a still hold is a swipe that goes nowhere - a long press.
            // std::clamp on one type: Qt 6's mixed-type qBound overloads make
            // qBound<qint64>(int, qint64, int) ambiguous (C2666).
            const int duration = int(std::clamp<qint64>(held, qint64(kMinSwipeMs), qint64(kMaxSwipeMs)));
            const QPoint to = moved <= kTapSlopPx ? m_pressAt : end;
            send(QString("input swipe %1 %2 %3 %4 %5")
                     .arg(m_pressAt.x()).arg(m_pressAt.y())
                     .arg(to.x()).arg(to.y()).arg(duration));
        }
        break;
    }
    case InputEventType::RightMouseDown:
        send(QStringLiteral("input keyevent 4"));   // Back
        break;
    case InputEventType::ScrollWheel: {
        if (event.keyCode != 0) break;             // pinch, rotate: nothing to map
        m_scrollAccum += event.deltaY;
        const qint64 now = nowMs();
        if (now - m_lastScrollMs < kScrollThrottleMs || std::abs(m_scrollAccum) < 1.0) break;
        m_lastScrollMs = now;

        // The receive window sends wheels without a position; swipe through the
        // middle of the screen then.
        const bool noPosition = event.x == 0.0 && event.y == 0.0;
        const QPoint from = toPhone(noPosition ? 0.5 : event.x, noPosition ? 0.5 : event.y);
        const QPoint size = toPhone(1.0, 1.0);
        // Wheel up (positive) should move content down, which on a touchscreen
        // is a finger swipe downwards.
        const int span = qBound(100, int(std::abs(m_scrollAccum) * 6.0), qMax(100, size.y() / 3));
        const int toY = qBound(0, from.y() + (m_scrollAccum > 0 ? span : -span), size.y());
        m_scrollAccum = 0.0;
        send(QString("input swipe %1 %2 %1 %3 120").arg(from.x()).arg(from.y()).arg(toY));
        break;
    }
    case InputEventType::KeyDown: {
        const int code = androidKeyCode(event.keyCode);
        if (code > 0) send(QString("input keyevent %1").arg(code));
        break;
    }
    default:
        break;
    }
}

int AdbInputInjector::androidKeyCode(uint16_t macKeyCode) {
    switch (macKeyCode) {
    // Same specials as the macOS receiver.
    case 36:  return 66;    // Return
    case 51:  return 67;    // Delete (backspace)
    case 53:  return 4;     // Escape -> Back
    case 48:  return 61;    // Tab
    case 49:  return 62;    // Space
    case 123: return 21;    // Left
    case 124: return 22;    // Right
    case 125: return 20;    // Down
    case 126: return 19;    // Up
    case 115: return 122;   // Home
    case 119: return 123;   // End
    case 116: return 92;    // Page Up
    case 121: return 93;    // Page Down
    // Letters (KEYCODE_A = 29 ... KEYCODE_Z = 54), by macOS virtual key code.
    case 0:  return 29;  case 11: return 30;  case 8:  return 31;  case 2:  return 32;
    case 14: return 33;  case 3:  return 34;  case 5:  return 35;  case 4:  return 36;
    case 34: return 37;  case 38: return 38;  case 40: return 39;  case 37: return 40;
    case 46: return 41;  case 45: return 42;  case 31: return 43;  case 35: return 44;
    case 12: return 45;  case 15: return 46;  case 1:  return 47;  case 17: return 48;
    case 32: return 49;  case 9:  return 50;  case 13: return 51;  case 7:  return 52;
    case 16: return 53;  case 6:  return 54;
    // Digits (KEYCODE_0 = 7 ... KEYCODE_9 = 16).
    case 29: return 7;   case 18: return 8;   case 19: return 9;   case 20: return 10;
    case 21: return 11;  case 23: return 12;  case 22: return 13;  case 26: return 14;
    case 28: return 15;  case 25: return 16;
    // Punctuation that needs no shift.
    case 43: return 55;     // comma
    case 47: return 56;     // period
    case 27: return 69;     // minus
    case 24: return 70;     // equals
    case 44: return 76;     // slash
    default: return 0;
    }
}
