#pragma once

#include <QObject>
#include <QSize>
#include "InputEvent.h"

class VideoRenderer;

// Captures mouse/keyboard events from the video widget and converts
// them to normalized InputEvent objects for sending to the Mac sender.
class InputHandler : public QObject {
    Q_OBJECT

public:
    explicit InputHandler(QObject* parent = nullptr);

    // Install event filter on the renderer widget
    void attach(VideoRenderer* renderer);

    // Set the video content size for accurate coordinate normalization
    void setContentSize(QSize size);

signals:
    void inputEvent(const InputEvent& event);

protected:
    bool eventFilter(QObject* obj, QEvent* event) override;

private:
    // Normalize a widget-local point to 0-1 video coordinates,
    // accounting for letterboxing/pillarboxing
    struct NormalizedPoint { double x; double y; bool valid; };
    NormalizedPoint normalize(double widgetX, double widgetY) const;

    VideoRenderer* m_renderer = nullptr;
    QSize m_contentSize{1920, 1080};
};
