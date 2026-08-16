#include "InputHandler.h"
#include <QHash>
#include "VideoRenderer.h"

#include <QMouseEvent>
#include <QKeyEvent>
#include <QWheelEvent>
#include <QWidget>

InputHandler::InputHandler(QObject* parent)
    : QObject(parent)
{
}

void InputHandler::attach(VideoRenderer* renderer) {
    m_renderer = renderer;
    renderer->installEventFilter(this);
    renderer->setMouseTracking(true);
    renderer->setFocusPolicy(Qt::StrongFocus);
}

void InputHandler::setContentSize(QSize size) {
    m_contentSize = size;
}

InputHandler::NormalizedPoint InputHandler::normalize(double widgetX, double widgetY) const {
    if (!m_renderer) return {0, 0, false};

    double viewW = m_renderer->width();
    double viewH = m_renderer->height();
    double contentW = m_contentSize.width();
    double contentH = m_contentSize.height();

    if (viewW <= 0 || viewH <= 0 || contentW <= 0 || contentH <= 0) {
        return {0, 0, false};
    }

    // Calculate aspect-ratio-correct video rect (matching VideoRenderer letterboxing)
    double widthRatio = viewW / contentW;
    double heightRatio = viewH / contentH;
    double scale = std::min(widthRatio, heightRatio);

    double videoW = contentW * scale;
    double videoH = contentH * scale;

    double xOffset = (viewW - videoW) / 2.0;
    double yOffset = (viewH - videoH) / 2.0;

    // Convert to video-relative coords
    double relX = widgetX - xOffset;
    double relY = widgetY - yOffset;

    // Check if in black bars
    if (relX < 0 || relX > videoW || relY < 0 || relY > videoH) {
        return {0, 0, false};
    }

    // Normalize 0-1 (Qt Y=0 is top, which matches what the sender expects)
    double normX = relX / videoW;
    double normY = relY / videoH;

    return {normX, normY, true};
}

namespace {

/// Translate a Qt key to a macOS virtual keycode.
///
/// The Mac host feeds whatever arrives straight into CGKeyCode, so the wire carries
/// macOS keycodes — the same space the iOS receiver already sends. This used to send
/// QKeyEvent::nativeVirtualKey(), which is a Windows VK code on Windows and an X11
/// keycode on Linux; neither resembles the macOS layout, so every letter came out
/// wrong. 'A' is VK 0x41 on Windows but keycode 0 on macOS, and macOS keycode 0x41
/// is the keypad decimal point.
///
/// Qt::Key is used rather than the native code so one table serves both platforms.
/// macOS keycodes are positional, not alphabetical — the order below looks scrambled
/// because it follows the physical ANSI layout.
uint16_t qtKeyToMacKeyCode(int qtKey) {
    static const QHash<int, uint16_t> map = {
        // Letters (positional order on the physical keyboard)
        {Qt::Key_A, 0},  {Qt::Key_S, 1},  {Qt::Key_D, 2},  {Qt::Key_F, 3},
        {Qt::Key_H, 4},  {Qt::Key_G, 5},  {Qt::Key_Z, 6},  {Qt::Key_X, 7},
        {Qt::Key_C, 8},  {Qt::Key_V, 9},  {Qt::Key_B, 11}, {Qt::Key_Q, 12},
        {Qt::Key_W, 13}, {Qt::Key_E, 14}, {Qt::Key_R, 15}, {Qt::Key_Y, 16},
        {Qt::Key_T, 17}, {Qt::Key_O, 31}, {Qt::Key_U, 32}, {Qt::Key_I, 34},
        {Qt::Key_P, 35}, {Qt::Key_L, 37}, {Qt::Key_J, 38}, {Qt::Key_K, 40},
        {Qt::Key_N, 45}, {Qt::Key_M, 46},

        // Digits — note 5 and 6 are not in numeric order on macOS
        {Qt::Key_1, 18}, {Qt::Key_2, 19}, {Qt::Key_3, 20}, {Qt::Key_4, 21},
        {Qt::Key_6, 22}, {Qt::Key_5, 23}, {Qt::Key_9, 25}, {Qt::Key_7, 26},
        {Qt::Key_8, 28}, {Qt::Key_0, 29},

        // Punctuation
        {Qt::Key_Equal, 24},        {Qt::Key_Minus, 27},
        {Qt::Key_BracketRight, 30}, {Qt::Key_BracketLeft, 33},
        {Qt::Key_Apostrophe, 39},   {Qt::Key_Semicolon, 41},
        {Qt::Key_Backslash, 42},    {Qt::Key_Comma, 43},
        {Qt::Key_Slash, 44},        {Qt::Key_Period, 47},
        {Qt::Key_QuoteLeft, 50},

        // Editing and navigation. macOS keycode 51 is Backspace; 117 is forward Delete.
        {Qt::Key_Return, 36},    {Qt::Key_Enter, 36},
        {Qt::Key_Tab, 48},       {Qt::Key_Space, 49},
        {Qt::Key_Backspace, 51}, {Qt::Key_Escape, 53},
        {Qt::Key_Delete, 117},
        {Qt::Key_Home, 115},     {Qt::Key_End, 119},
        {Qt::Key_PageUp, 116},   {Qt::Key_PageDown, 121},
        {Qt::Key_Left, 123},     {Qt::Key_Right, 124},
        {Qt::Key_Down, 125},     {Qt::Key_Up, 126},

        // Modifiers. Windows/Meta maps to Command and Alt to Option, matching the
        // physical position. Ctrl stays Control, so Ctrl+C arrives as Control+C and
        // will NOT copy on macOS — swapping it for Command is a separate UX call.
        {Qt::Key_Shift, 56},   {Qt::Key_CapsLock, 57},
        {Qt::Key_Alt, 58},     {Qt::Key_Control, 59},
        {Qt::Key_Meta, 55},

        // Function row — also non-sequential on macOS
        {Qt::Key_F1, 122},  {Qt::Key_F2, 120},  {Qt::Key_F3, 99},
        {Qt::Key_F4, 118},  {Qt::Key_F5, 96},   {Qt::Key_F6, 97},
        {Qt::Key_F7, 98},   {Qt::Key_F8, 100},  {Qt::Key_F9, 101},
        {Qt::Key_F10, 109}, {Qt::Key_F11, 103}, {Qt::Key_F12, 111},
    };
    return map.value(qtKey, 0xFFFF); // 0xFFFF = unmapped, caller drops it
}

} // namespace

bool InputHandler::eventFilter(QObject* obj, QEvent* event) {
    switch (event->type()) {
    case QEvent::MouseMove: {
        auto* me = static_cast<QMouseEvent*>(event);
        auto pos = me->position();
        auto np = normalize(pos.x(), pos.y());
        if (np.valid) {
            emit inputEvent(InputEvent(InputEventType::MouseMove, np.x, np.y));
        }
        return false;
    }
    case QEvent::MouseButtonPress: {
        auto* me = static_cast<QMouseEvent*>(event);
        auto pos = me->position();
        auto np = normalize(pos.x(), pos.y());
        if (np.valid) {
            auto type = (me->button() == Qt::RightButton)
                ? InputEventType::RightMouseDown
                : InputEventType::LeftMouseDown;
            emit inputEvent(InputEvent(type, np.x, np.y));
        }
        return false;
    }
    case QEvent::MouseButtonRelease: {
        auto* me = static_cast<QMouseEvent*>(event);
        auto pos = me->position();
        auto np = normalize(pos.x(), pos.y());
        if (np.valid) {
            auto type = (me->button() == Qt::RightButton)
                ? InputEventType::RightMouseUp
                : InputEventType::LeftMouseUp;
            emit inputEvent(InputEvent(type, np.x, np.y));
        }
        return false;
    }
    case QEvent::Wheel: {
        auto* we = static_cast<QWheelEvent*>(event);
        QPointF delta = we->angleDelta();
        double dx = delta.x();
        double dy = delta.y();
        // Qt gives 120ths of a degree per step. Scale for usable values.
        dx /= 12.0;
        dy /= 12.0;
        if (dx != 0 || dy != 0) {
            emit inputEvent(InputEvent(InputEventType::ScrollWheel, 0, 0, 0, dx, dy));
        }
        return false;
    }
    case QEvent::KeyPress: {
        auto* ke = static_cast<QKeyEvent*>(event);
        const uint16_t mac = qtKeyToMacKeyCode(ke->key());
        if (mac == 0xFFFF) return false; // unmapped key — better silent than wrong
        emit inputEvent(InputEvent(InputEventType::KeyDown, 0, 0, mac));
        return false;
    }
    case QEvent::KeyRelease: {
        auto* ke = static_cast<QKeyEvent*>(event);
        const uint16_t mac = qtKeyToMacKeyCode(ke->key());
        if (mac == 0xFFFF) return false;
        emit inputEvent(InputEvent(InputEventType::KeyUp, 0, 0, mac));
        return false;
    }
    default:
        break;
    }

    return QObject::eventFilter(obj, event);
}
