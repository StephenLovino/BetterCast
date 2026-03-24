#include "MainWindow.h"
#include "VideoDecoder.h"
#include "VideoRenderer.h"
#include "NetworkListener.h"
#include "InputHandler.h"
#include "ServiceDiscovery.h"

#include <QVBoxLayout>
#include <QHBoxLayout>
#include <QScreen>
#include <QApplication>
#include <QDebug>

MainWindow::MainWindow(QWidget* parent)
    : QMainWindow(parent)
{
    setWindowTitle("BetterCast Receiver");
    setMinimumSize(640, 400);

    // Create components
    m_decoder = new VideoDecoder(this);
    m_renderer = new VideoRenderer();
    m_network = new NetworkListener(this);
    m_inputHandler = new InputHandler(this);
    m_discovery = new ServiceDiscovery(this);

    // Wire up
    m_network->setup(m_decoder, m_renderer);

    // Decoder → Renderer
    connect(m_decoder, &VideoDecoder::frameDecoded,
            m_renderer, &VideoRenderer::onFrameDecoded);
    connect(m_decoder, &VideoDecoder::dimensionsChanged,
            m_renderer, [this](int w, int h) {
                m_inputHandler->setContentSize(QSize(w, h));
            });

    // Input → Network
    m_inputHandler->attach(m_renderer);
    connect(m_inputHandler, &InputHandler::inputEvent,
            m_network, &NetworkListener::sendInputEvent);

    // Network status → UI
    connect(m_network, &NetworkListener::connectionEstablished,
            this, &MainWindow::onConnectionEstablished);
    connect(m_network, &NetworkListener::connectionLost,
            this, &MainWindow::onConnectionLost);
    connect(m_network, &NetworkListener::statusChanged,
            this, &MainWindow::onStatusChanged);

    // Video size → window resize
    connect(m_renderer, &VideoRenderer::videoSizeChanged,
            this, &MainWindow::onVideoSizeChanged);

    setupUi();

    // Start listening
    m_network->start();
    m_discovery->startAdvertising(51820);

    // Default landscape size
    QScreen* screen = QApplication::primaryScreen();
    if (screen) {
        QRect available = screen->availableGeometry();
        int w = static_cast<int>(available.width() * 0.7);
        int h = w * 9 / 16;
        int x = available.x() + (available.width() - w) / 2;
        int y = available.y() + (available.height() - h) / 2;
        setGeometry(x, y, w, h);
    }
}

MainWindow::~MainWindow() {
    m_discovery->stopAdvertising();
}

void MainWindow::setupUi() {
    m_stack = new QStackedWidget(this);
    setCentralWidget(m_stack);

    // Page 0: Connection UI (shown when disconnected)
    m_connectPage = new QWidget();
    auto* connectLayout = new QVBoxLayout(m_connectPage);
    connectLayout->setAlignment(Qt::AlignCenter);

    m_statusLabel = new QLabel("Waiting for connection...");
    m_statusLabel->setStyleSheet("color: orange; font-size: 16px; font-weight: bold;");
    m_statusLabel->setAlignment(Qt::AlignCenter);
    connectLayout->addWidget(m_statusLabel);

    connectLayout->addSpacing(20);

    // Manual connect row
    auto* connectRow = new QHBoxLayout();
    m_hostEdit = new QLineEdit("localhost");
    m_hostEdit->setPlaceholderText("Host");
    m_hostEdit->setFixedWidth(180);
    connectRow->addWidget(m_hostEdit);

    m_portEdit = new QLineEdit("51820");
    m_portEdit->setPlaceholderText("Port");
    m_portEdit->setFixedWidth(80);
    connectRow->addWidget(m_portEdit);

    m_connectBtn = new QPushButton("Connect");
    m_connectBtn->setDefault(true);
    connect(m_connectBtn, &QPushButton::clicked, this, &MainWindow::onConnectClicked);
    connectRow->addWidget(m_connectBtn);

    connectLayout->addLayout(connectRow);

    m_connectPage->setStyleSheet("background-color: black;");
    m_stack->addWidget(m_connectPage);

    // Page 1: Video renderer (shown when connected)
    m_renderer->setStyleSheet("background-color: black;");
    m_stack->addWidget(m_renderer);

    m_stack->setCurrentIndex(0);
}

void MainWindow::onConnectClicked() {
    bool ok = false;
    uint16_t port = m_portEdit->text().toUShort(&ok);
    if (!ok) port = 51820;

    m_network->connectTo(m_hostEdit->text(), port);
    m_connectBtn->setEnabled(false);
    m_statusLabel->setText("Connecting...");
}

void MainWindow::onConnectionEstablished() {
    m_stack->setCurrentIndex(1); // Show video
    m_connectBtn->setEnabled(true);
}

void MainWindow::onConnectionLost() {
    m_stack->setCurrentIndex(0); // Show connect UI
    m_statusLabel->setText("Connection lost. Reconnect?");
    m_connectBtn->setEnabled(true);
}

void MainWindow::onStatusChanged(const QString& status) {
    m_statusLabel->setText(status);
}

void MainWindow::onVideoSizeChanged(QSize size) {
    if (size.width() > 0 && size.height() > 0) {
        resizeToFitVideo(size.width(), size.height());
    }
}

void MainWindow::resizeToFitVideo(int videoWidth, int videoHeight) {
    QScreen* screen = QApplication::primaryScreen();
    if (!screen) return;

    QRect available = screen->availableGeometry();
    double aspect = static_cast<double>(videoWidth) / videoHeight;
    bool landscape = videoWidth > videoHeight;

    int winW, winH;
    if (landscape) {
        winW = std::min(static_cast<int>(available.width() * 0.8), videoWidth);
        winH = static_cast<int>(winW / aspect);
        if (winH > available.height() * 0.85) {
            winH = static_cast<int>(available.height() * 0.85);
            winW = static_cast<int>(winH * aspect);
        }
    } else {
        winH = std::min(static_cast<int>(available.height() * 0.75), videoHeight);
        winW = static_cast<int>(winH * aspect);
        if (winW > available.width() * 0.9) {
            winW = static_cast<int>(available.width() * 0.9);
            winH = static_cast<int>(winW / aspect);
        }
    }

    winW = std::max(winW, 320);
    winH = std::max(winH, 200);

    int x = available.x() + (available.width() - winW) / 2;
    int y = available.y() + (available.height() - winH) / 2;

    qDebug() << "Resizing window to" << winW << "x" << winH
             << "for video" << videoWidth << "x" << videoHeight;

    setGeometry(x, y, winW, winH);
}
