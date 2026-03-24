#include "InputHandler.h"
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
        // Send Qt native key code — sender will need a mapping table
        // For now we send the Qt key code directly
        emit inputEvent(InputEvent(InputEventType::KeyDown, 0, 0,
                                   static_cast<uint16_t>(ke->nativeVirtualKey())));
        return false;
    }
    case QEvent::KeyRelease: {
        auto* ke = static_cast<QKeyEvent*>(event);
        emit inputEvent(InputEvent(InputEventType::KeyUp, 0, 0,
                                   static_cast<uint16_t>(ke->nativeVirtualKey())));
        return false;
    }
    default:
        break;
    }

    return QObject::eventFilter(obj, event);
}
