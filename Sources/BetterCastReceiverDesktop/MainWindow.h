#pragma once

#include <QMainWindow>
#include <QLabel>
#include <QLineEdit>
#include <QPushButton>
#include <QStackedWidget>
#include <QSplitter>
#include <QListWidget>
#include <QTextEdit>
#include <QComboBox>
#include <QCheckBox>
#include <QSpinBox>
#include <QTimer>
#include <QSize>
#include <QMouseEvent>
#include <QStringList>
#include <QTime>

// Simple log manager (mirrors macOS LogManager)
class LogManager : public QObject {
    Q_OBJECT
public:
    static LogManager& instance() {
        static LogManager lm;
        return lm;
    }

    void log(const QString& msg) {
        QString entry = QString("[%1] %2")
            .arg(QTime::currentTime().toString("HH:mm:ss"), msg);
        m_entries.append(entry);
        if (m_entries.size() > 200) m_entries.removeFirst();
        qDebug().noquote() << msg;
        emit logAdded(entry);
    }

    void clear() { m_entries.clear(); }
    const QStringList& entries() const { return m_entries; }

signals:
    void logAdded(const QString& entry);

private:
    LogManager() = default;
    QStringList m_entries;
};

struct DiscoveredService;
class VideoRenderer;
class VideoDecoder;
class NetworkListener;
class InputHandler;
class ServiceDiscovery;
class AudioDecoder;
class AudioPlayer;
class AdbHelper;
#ifdef ENABLE_SENDER
class SenderController;
#endif

class MainWindow : public QMainWindow {
    Q_OBJECT

public:
    explicit MainWindow(QWidget* parent = nullptr);
    ~MainWindow();

private slots:
    void onSidebarSelectionChanged(int row);
    void onConnectClicked();
    void onAdbConnectClicked();
    void onConnectionEstablished();
    void onConnectionLost();
    void onStatusChanged(const QString& status);
    void onVideoSizeChanged(QSize size);
    void attemptAdbReconnect();
    void onLogAdded(const QString& entry);
    void onCopyLogs();
    void onClearLogs();
    void onReportIssue();
#ifdef ENABLE_SENDER
    void onSendScreenClicked();
    void onStopSendingClicked();
    void onReceiverDiscovered(const DiscoveredService& service);
    void onReceiverSelected(int index);
#endif

private:
    void keyPressEvent(QKeyEvent* event) override;
    void mouseDoubleClickEvent(QMouseEvent* event) override;
    void setupUi();
    void setupSidebar();
    void setupOverviewPage();
    void setupReceivePage();
    void setupSettingsPage();
    void setupLogsPage();
#ifdef ENABLE_SENDER
    void setupSendPage();
#endif
    void resizeToFitVideo(int videoWidth, int videoHeight);
    void updateLocalIpDisplay();
    void selectSidebarItem(int pageIndex);
    void toggleFullscreen();

    // Core components
    VideoDecoder* m_decoder = nullptr;
    VideoRenderer* m_renderer = nullptr;
    NetworkListener* m_network = nullptr;
    InputHandler* m_inputHandler = nullptr;
    ServiceDiscovery* m_discovery = nullptr;
    AudioDecoder* m_audioDecoder = nullptr;
    AudioPlayer* m_audioPlayer = nullptr;
    AdbHelper* m_adbHelper = nullptr;
    QTimer* m_reconnectTimer = nullptr;
    int m_reconnectAttempts = 0;
    bool m_wirelessAdbEnabled = false;
#ifdef ENABLE_SENDER
    SenderController* m_sender = nullptr;
#endif

    // Layout
    QSplitter* m_splitter = nullptr;
    QListWidget* m_sidebarList = nullptr;
    QStackedWidget* m_stack = nullptr;

    // Page indices (set during setupUi based on ENABLE_SENDER)
    int m_pageOverview = -1;
    int m_pageSend = -1;     // only if ENABLE_SENDER
    int m_pageReceive = -1;
    int m_pageSettings = -1;
    int m_pageLogs = -1;
    int m_pageVideo = -1;

    // Overview page
    QLabel* m_overviewStatusLabel = nullptr;
    QLabel* m_overviewIpLabel = nullptr;

    // Receive page
    QLabel* m_recvStatusLabel = nullptr;
    QLabel* m_recvIpLabel = nullptr;
    QLineEdit* m_hostEdit = nullptr;
    QLineEdit* m_portEdit = nullptr;
    QPushButton* m_connectBtn = nullptr;
    QPushButton* m_adbBtn = nullptr;
    QLabel* m_adbHelpLabel = nullptr;

    // Settings page
    QLabel* m_versionLabel = nullptr;

    // Logs page
    QTextEdit* m_logViewer = nullptr;

    // Video page toolbar
    QWidget* m_videoContainer = nullptr;
    QWidget* m_videoToolbar = nullptr;

#ifdef ENABLE_SENDER
    // Send page
    QComboBox* m_receiverCombo = nullptr;
    QLineEdit* m_sendHostEdit = nullptr;
    QSpinBox* m_fpsSpinBox = nullptr;
    QSpinBox* m_bitrateSpinBox = nullptr;
    QPushButton* m_sendBtn = nullptr;
    QPushButton* m_stopSendBtn = nullptr;
    QLabel* m_senderStatusLabel = nullptr;
#endif
};
