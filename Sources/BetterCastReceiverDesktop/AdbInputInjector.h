#pragma once

#include <QObject>
#include <QPoint>
#include <QSize>
#include <QString>

#include "InputEvent.h"

class QProcess;

// Controls an Android phone from its mirrored screen, over adb.
//
// A phone streaming its screen in BetterCast's Send mode ignores the input
// events sent back down the stream. When the stream came through the USB cable
// (or wireless adb) there is another way in: `adb shell input`. The macOS
// receiver does the same (ADBInputInjector in ReceiverNetworkListener.swift),
// launching one adb process per event. Here one `adb shell` stays open and
// commands are written to it, because starting adb.exe per click on Windows is
// slow enough to feel.
//
// Mapping, from the receive window's normalised events:
//   click                 -> input tap
//   drag                  -> input swipe from press to release, over the same time
//   hold without moving   -> input swipe in place (a long press)
//   right click           -> Back
//   wheel                 -> a short swipe, throttled
//   Return, Delete, Tab, Space, arrows, Home/End, Page Up/Down, Escape (Back),
//   letters and digits    -> input keyevent
// Must live on a thread with an event loop (the GUI thread).
class AdbInputInjector : public QObject {
    Q_OBJECT
public:
    // phoneScreen is `wm size` in portrait pixels; serial may be empty when
    // adb has only one device.
    AdbInputInjector(const QString& adbPath, const QString& serial, QSize phoneScreen,
                     QObject* parent = nullptr);
    ~AdbInputInjector() override;

    // The stream's size. A landscape stream from a portrait-sized phone means
    // the phone is rotated, so its axes swap.
    void setStreamSize(int width, int height);

    void inject(const InputEvent& event);

private:
    bool ensureShell();
    void send(const QString& command);
    QPoint toPhone(double nx, double ny) const;
    static int androidKeyCode(uint16_t macKeyCode);

    QString m_adbPath;
    QString m_serial;
    QSize m_phoneScreen;
    QSize m_streamSize;
    QProcess* m_shell = nullptr;

    bool m_pressed = false;
    QPoint m_pressAt;
    QPoint m_lastPoint;
    qint64 m_pressMs = 0;

    double m_scrollAccum = 0.0;
    qint64 m_lastScrollMs = 0;
};
