#include "VideoWindow.h"
#include "VideoRenderer.h"
#include "InputHandler.h"
#include "MainWindow.h"  // for LogManager

#include <QDebug>

VideoWindow::VideoWindow(VideoRenderer* renderer, InputHandler* inputHandler, QWidget* parent)
    : QMainWindow(parent)
    , m_renderer(renderer)
    , m_inputHandler(inputHandler)
{
    setWindowTitle("BetterCast — Receiving");
    setStyleSheet("background-color: black;");
    setMinimumSize(320, 180);

    auto* central = new QWidget();
    central->setStyleSheet("background-color: black;");
    auto* layout = new QVBoxLayout(central);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(0);

    // Toolbar at top
    m_toolbar = new QWidget();
    m_toolbar->setFixedHeight(36);
    m_toolbar->setStyleSheet(
        "QWidget { background-color: rgba(0,0,0,0.7); }"
        "QPushButton { background-color: transparent; color: #ccc; border: none;"
        "  padding: 4px 12px; font-size: 12px; border-radius: 4px; }"
        "QPushButton:hover { background-color: rgba(255,255,255,0.15); color: #fff; }"
    );
    auto* tbLayout = new QHBoxLayout(m_toolbar);
    tbLayout->setContentsMargins(8, 2, 8, 2);

    auto* fullscreenBtn = new QPushButton("[ ] Fullscreen");
    connect(fullscreenBtn, &QPushButton::clicked, this, &VideoWindow::toggleFullscreen);

    tbLayout->addStretch();
    tbLayout->addWidget(fullscreenBtn);

    layout->addWidget(m_toolbar);
    layout->addWidget(m_renderer, 1);

    setCentralWidget(central);
}

VideoWindow::~VideoWindow() {
    // Don't delete the renderer — it's owned by MainWindow
    if (m_renderer) {
        m_renderer->setParent(nullptr);
    }
}

void VideoWindow::showForVideo() {
    if (isVisible()) {
        raise();
        activateWindow();
        return;
    }

    // Position to the right of the main window if possible
    QWidget* mainWin = parentWidget();
    QScreen* screen = QApplication::primaryScreen();
    QRect available = screen ? screen->availableGeometry()
                             : QRect(0, 0, 1920, 1080);

    int winW = 960;
    int winH = 540;

    if (mainWin) {
        QRect mainFrame = mainWin->geometry();
        int rightX = mainFrame.right() + 12;
        if (rightX + winW <= available.right()) {
            move(rightX, mainFrame.center().y() - winH / 2);
        } else {
            int leftX = mainFrame.left() - winW - 12;
            move(qMax(leftX, available.left()), mainFrame.center().y() - winH / 2);
        }
    } else {
        move(available.center().x() - winW / 2, available.center().y() - winH / 2);
    }

    resize(winW, winH);
    show();
    LogManager::instance().log("Video window opened");
}

void VideoWindow::resizeToFitVideo(int videoWidth, int videoHeight) {
    if (videoWidth <= 0 || videoHeight <= 0) return;

    QSize newSize(videoWidth, videoHeight);
    if (newSize == m_lastVideoSize) return;
    m_lastVideoSize = newSize;

    QScreen* screen = QApplication::primaryScreen();
    if (!screen) return;
    QRect available = screen->availableGeometry();

    double aspect = static_cast<double>(videoWidth) / videoHeight;
    bool landscape = videoWidth > videoHeight;

    int winW, winH;
    if (landscape) {
        winW = qMin(static_cast<int>(available.width() * 0.6), videoWidth);
        winH = static_cast<int>(winW / aspect);
        if (winH > available.height() * 0.8) {
            winH = static_cast<int>(available.height() * 0.8);
            winW = static_cast<int>(winH * aspect);
        }
    } else {
        winH = qMin(static_cast<int>(available.height() * 0.75), videoHeight);
        winW = static_cast<int>(winH * aspect);
        if (winW > available.width() * 0.5) {
            winW = static_cast<int>(available.width() * 0.5);
            winH = static_cast<int>(winW / aspect);
        }
    }

    winW = qMax(winW, 320);
    winH = qMax(winH, 180);

    // Keep centered on current center
    QRect cur = geometry();
    int x = cur.center().x() - winW / 2;
    int y = cur.center().y() - winH / 2;
    x = qMax(available.left(), qMin(x, available.right() - winW));
    y = qMax(available.top(), qMin(y, available.bottom() - winH));

    qDebug() << "VideoWindow: Resizing to" << winW << "x" << winH
             << "for video" << videoWidth << "x" << videoHeight;

    setGeometry(x, y, winW, winH);
}

void VideoWindow::keyPressEvent(QKeyEvent* event) {
    if (event->key() == Qt::Key_F11) {
        toggleFullscreen();
        return;
    }
    if (event->key() == Qt::Key_Escape) {
        if (isFullScreen()) {
            toggleFullscreen();
            return;
        }
    }
    QMainWindow::keyPressEvent(event);
}

void VideoWindow::mouseDoubleClickEvent(QMouseEvent* event) {
    toggleFullscreen();
    event->accept();
}

void VideoWindow::closeEvent(QCloseEvent* event) {
    if (isFullScreen()) {
        showNormal();
    }
    // Re-parent renderer back so it's not destroyed with us
    if (m_renderer) {
        m_renderer->setParent(nullptr);
        m_renderer->hide();
    }
    emit windowClosed();
    QMainWindow::closeEvent(event);
}

void VideoWindow::toggleFullscreen() {
    if (isFullScreen()) {
        if (m_toolbar) m_toolbar->show();
        showNormal();
        LogManager::instance().log("Exited fullscreen");
    } else {
        if (m_toolbar) m_toolbar->hide();
        showFullScreen();
        LogManager::instance().log("Entered fullscreen (F11 or Escape to exit)");
    }
}
