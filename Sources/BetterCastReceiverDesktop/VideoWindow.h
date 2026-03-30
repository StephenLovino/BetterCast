#pragma once

#include <QMainWindow>
#include <QPushButton>
#include <QVBoxLayout>
#include <QHBoxLayout>
#include <QKeyEvent>
#include <QMouseEvent>
#include <QScreen>
#include <QApplication>
#include <QSize>

class VideoRenderer;
class InputHandler;

class VideoWindow : public QMainWindow {
    Q_OBJECT

public:
    explicit VideoWindow(VideoRenderer* renderer, InputHandler* inputHandler, QWidget* parent = nullptr);
    ~VideoWindow();

    void showForVideo();
    void resizeToFitVideo(int videoWidth, int videoHeight);

signals:
    void windowClosed();

protected:
    void keyPressEvent(QKeyEvent* event) override;
    void mouseDoubleClickEvent(QMouseEvent* event) override;
    void closeEvent(QCloseEvent* event) override;

private:
    void toggleFullscreen();

    VideoRenderer* m_renderer = nullptr;
    InputHandler* m_inputHandler = nullptr;
    QWidget* m_toolbar = nullptr;
    QSize m_lastVideoSize;
};
