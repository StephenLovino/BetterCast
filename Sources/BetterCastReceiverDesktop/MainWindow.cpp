#include "MainWindow.h"
#include "VideoDecoder.h"
#include "VideoRenderer.h"
#include "NetworkListener.h"
#include "InputHandler.h"
#include "ServiceDiscovery.h"
#include "AudioDecoder.h"
#include "AudioPlayer.h"
#include "AdbHelper.h"
#ifdef ENABLE_SENDER
#include "sender/SenderController.h"
#endif

#include <QVBoxLayout>
#include <QHBoxLayout>
#include <QScreen>
#include <QApplication>
#include <QDebug>
#include <QNetworkInterface>
#include <thread>

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
    m_audioDecoder = new AudioDecoder(this);
    m_audioPlayer = new AudioPlayer(this);
    m_adbHelper = new AdbHelper(this);
    m_reconnectTimer = new QTimer(this);
    m_reconnectTimer->setInterval(3000); // 3 seconds between attempts
    connect(m_reconnectTimer, &QTimer::timeout, this, &MainWindow::attemptAdbReconnect);
#ifdef ENABLE_SENDER
    m_sender = new SenderController(this);
    connect(m_sender, &SenderController::statusChanged, this, &MainWindow::onStatusChanged);
    connect(m_sender, &SenderController::error, this, [this](const QString& msg) {
        onStatusChanged("Sender error: " + msg);
    });
    connect(m_sender, &SenderController::connected, this, [this]() {
        onStatusChanged("Sending screen...");
    });
    connect(m_sender, &SenderController::stopped, this, [this]() {
        m_sendBtn->setEnabled(true);
        m_stopSendBtn->setEnabled(false);
        m_sendHostEdit->setEnabled(true);
    });
#endif

    // Wire up
    m_network->setup(m_decoder, m_renderer, m_audioDecoder);

    // Audio: decoder → player
    connect(m_audioDecoder, &AudioDecoder::pcmDecoded,
            m_audioPlayer, &AudioPlayer::onPcmDecoded);

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

    // ADB status → UI
    connect(m_adbHelper, &AdbHelper::statusChanged,
            this, &MainWindow::onStatusChanged);

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

    // Show local IP addresses so the user knows what to enter on the sender
    m_ipLabel = new QLabel();
    m_ipLabel->setStyleSheet("color: #aaaaaa; font-size: 13px;");
    m_ipLabel->setAlignment(Qt::AlignCenter);
    m_ipLabel->setWordWrap(true);
    updateLocalIpDisplay();
    connectLayout->addWidget(m_ipLabel);

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

    connectLayout->addSpacing(15);

    // Android ADB connect section
    m_adbBtn = new QPushButton("Connect to Android (ADB)");
    m_adbBtn->setStyleSheet(
        "QPushButton { background-color: #3ddc84; color: black; font-weight: bold; "
        "padding: 8px 16px; border-radius: 6px; font-size: 14px; }"
        "QPushButton:hover { background-color: #50e898; }"
        "QPushButton:disabled { background-color: #555555; color: #888888; }");
    m_adbBtn->setFixedWidth(280);
    connect(m_adbBtn, &QPushButton::clicked, this, &MainWindow::onAdbConnectClicked);
    connectLayout->addWidget(m_adbBtn, 0, Qt::AlignCenter);

    m_adbHelpLabel = new QLabel(
        "To mirror your Android screen:\n"
        "1. Enable Developer Options (tap Build Number 7x in Settings > About)\n"
        "2. Enable USB Debugging in Developer Options\n"
        "3. Connect Android to this computer via USB\n"
        "4. Open BetterCast on Android and tap \"Start Casting\"\n"
        "5. Click the button above to connect");
    m_adbHelpLabel->setStyleSheet("color: #777777; font-size: 11px;");
    m_adbHelpLabel->setAlignment(Qt::AlignCenter);
    m_adbHelpLabel->setWordWrap(true);
    m_adbHelpLabel->setFixedWidth(400);
    connectLayout->addWidget(m_adbHelpLabel, 0, Qt::AlignCenter);

    // Sender section (when built with ENABLE_SENDER)
#ifdef ENABLE_SENDER
    connectLayout->addSpacing(20);

    auto* senderSeparator = new QLabel("— Send Screen —");
    senderSeparator->setStyleSheet("color: #555555; font-size: 12px;");
    senderSeparator->setAlignment(Qt::AlignCenter);
    connectLayout->addWidget(senderSeparator);

    connectLayout->addSpacing(5);

    auto* sendRow = new QHBoxLayout();
    m_sendHostEdit = new QLineEdit();
    m_sendHostEdit->setPlaceholderText("Receiver IP (e.g. 192.168.1.50)");
    m_sendHostEdit->setFixedWidth(220);
    sendRow->addWidget(m_sendHostEdit);

    m_sendBtn = new QPushButton("Send Screen");
    m_sendBtn->setStyleSheet(
        "QPushButton { background-color: #0078D4; color: white; font-weight: bold; "
        "padding: 8px 16px; border-radius: 6px; font-size: 14px; }"
        "QPushButton:hover { background-color: #1a8ae8; }"
        "QPushButton:disabled { background-color: #555555; color: #888888; }");
    connect(m_sendBtn, &QPushButton::clicked, this, &MainWindow::onSendScreenClicked);
    sendRow->addWidget(m_sendBtn);

    m_stopSendBtn = new QPushButton("Stop");
    m_stopSendBtn->setEnabled(false);
    m_stopSendBtn->setStyleSheet(
        "QPushButton { background-color: #d32f2f; color: white; font-weight: bold; "
        "padding: 8px 12px; border-radius: 6px; font-size: 14px; }"
        "QPushButton:hover { background-color: #e53935; }"
        "QPushButton:disabled { background-color: #555555; color: #888888; }");
    connect(m_stopSendBtn, &QPushButton::clicked, this, &MainWindow::onStopSendingClicked);
    sendRow->addWidget(m_stopSendBtn);

    connectLayout->addLayout(sendRow);

    m_senderStatusLabel = new QLabel("Enter a receiver's IP to stream your screen");
    m_senderStatusLabel->setStyleSheet("color: #777777; font-size: 11px;");
    m_senderStatusLabel->setAlignment(Qt::AlignCenter);
    connectLayout->addWidget(m_senderStatusLabel);
#endif

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

void MainWindow::onAdbConnectClicked() {
    m_adbBtn->setEnabled(false);
    m_adbBtn->setText("Setting up ADB...");
    m_statusLabel->setText("Looking for Android device...");

    // Run ADB setup in background thread to avoid blocking UI
    std::thread([this]() {
        bool success = m_adbHelper->setupForward(51820);
        QMetaObject::invokeMethod(this, [this, success]() {
            m_adbBtn->setEnabled(true);
            m_adbBtn->setText("Connect to Android (ADB)");

            if (success) {
                m_statusLabel->setText("ADB tunnel ready — connecting...");
                m_network->connectTo("localhost", 51820);
            }
        });
    }).detach();
}

void MainWindow::onConnectionEstablished() {
    m_stack->setCurrentIndex(1); // Show video
    m_connectBtn->setEnabled(true);
    m_reconnectTimer->stop();
    m_reconnectAttempts = 0;
}

void MainWindow::onConnectionLost() {
    m_stack->setCurrentIndex(0); // Show connect UI
    m_connectBtn->setEnabled(true);

    // Auto-reconnect if this was an ADB connection
    if (m_adbHelper->wasAdbConnection()) {
        m_reconnectAttempts = 0;
        m_statusLabel->setText("Connection lost — auto-reconnecting via ADB...");
        // Try immediately, then every 3 seconds
        attemptAdbReconnect();
        m_reconnectTimer->start();
    } else {
        m_statusLabel->setText("Connection lost. Reconnect?");
    }
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

void MainWindow::attemptAdbReconnect() {
    m_reconnectAttempts++;

    // Give up after 20 attempts (60 seconds)
    if (m_reconnectAttempts > 20) {
        m_reconnectTimer->stop();
        m_statusLabel->setText("Auto-reconnect failed. Click 'Connect to Android (ADB)' to retry.");
        return;
    }

    m_statusLabel->setText(QString("Reconnecting via ADB... (attempt %1)").arg(m_reconnectAttempts));

    // Run in background thread to avoid blocking UI
    std::thread([this]() {
        uint16_t port = m_adbHelper->lastPort();
        if (port == 0) port = 51820;

        bool success = m_adbHelper->setupForward(port);
        QMetaObject::invokeMethod(this, [this, success, port]() {
            if (success) {
                m_reconnectTimer->stop();
                m_statusLabel->setText("ADB tunnel restored — connecting...");
                m_network->connectTo("localhost", port);
            }
            // If failed, timer will fire again in 3 seconds
        });
    }).detach();
}

#ifdef ENABLE_SENDER
void MainWindow::onSendScreenClicked() {
    QString host = m_sendHostEdit->text().trimmed();
    if (host.isEmpty()) {
        m_senderStatusLabel->setText("Enter a receiver IP address first");
        return;
    }

    m_sendBtn->setEnabled(false);
    m_stopSendBtn->setEnabled(true);
    m_sendHostEdit->setEnabled(false);
    m_senderStatusLabel->setText("Starting sender...");

    m_sender->startSending(host, 51820, 30, 8);
}

void MainWindow::onStopSendingClicked() {
    m_sender->stopSending();
    m_senderStatusLabel->setText("Sender stopped");
}
#endif

void MainWindow::updateLocalIpDisplay() {
    QStringList ips;
    for (const auto& iface : QNetworkInterface::allInterfaces()) {
        if (iface.flags().testFlag(QNetworkInterface::IsUp) &&
            iface.flags().testFlag(QNetworkInterface::IsRunning) &&
            !iface.flags().testFlag(QNetworkInterface::IsLoopBack)) {
            for (const auto& entry : iface.addressEntries()) {
                if (entry.ip().protocol() == QAbstractSocket::IPv4Protocol) {
                    ips.append(entry.ip().toString());
                }
            }
        }
    }

    if (ips.isEmpty()) {
        m_ipLabel->setText("No network detected");
    } else {
        m_ipLabel->setText("This device: " + ips.join(" / ") + " : 51820");
    }
}
