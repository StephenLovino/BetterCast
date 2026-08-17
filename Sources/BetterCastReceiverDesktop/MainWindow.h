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
#include <QFile>
#include <QDir>
#include <QStandardPaths>

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
        if (m_entries.size() > 1000) m_entries.removeFirst();
        qDebug().noquote() << msg;
        writeToFile(entry);
        emit logAdded(entry);
    }

    void clear() { m_entries.clear(); }
    const QStringList& entries() const { return m_entries; }

    /// Where the on-disk log lives, so the UI can point users at it.
    QString logFilePath() const { return m_logPath; }

signals:
    void logAdded(const QString& entry);

private:
    /// Mirror every entry to disk as well as memory.
    ///
    /// The in-memory list dies with the process, which made every crash report
    /// useless: the app quits, the user reopens it to copy the logs, and all they can
    /// send is the *restarted* run. Three filed issues (#35, #42, #43) contain nothing
    /// but startup lines for exactly this reason.
    ///
    /// The previous run is kept as bettercast.log.1, so after a crash the evidence is
    /// still there once the app has been reopened.
    LogManager() {
        const QString dir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
        if (dir.isEmpty()) return;
        QDir().mkpath(dir);
        m_logPath = dir + "/bettercast.log";

        QFile::remove(m_logPath + ".1");
        QFile::rename(m_logPath, m_logPath + ".1");

        m_logFile.setFileName(m_logPath);
        m_logFile.open(QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text);
    }

    void writeToFile(const QString& entry) {
        if (!m_logFile.isOpen()) return;
        m_logFile.write(entry.toUtf8());
        m_logFile.write("\n");
        // Flush every line. Buffered writes are exactly what gets lost when the process
        // dies, and the last few lines before a crash are the ones worth having.
        m_logFile.flush();
    }

    QStringList m_entries;
    QFile m_logFile;
    QString m_logPath;
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
class VideoWindow;
#ifdef ENABLE_SENDER
class SenderController;
class VirtualDisplayVDD;
class InviteListener;
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
    void onCreateVirtualDisplay();
    void onRemoveVirtualDisplay();
    void onRefreshMonitors();
    void onMonitorSelected(int index);
    void onInviteReceived(const QString& deviceName, const QString& peerAddress);
#endif

private:
    void setupUi();
    void setupSidebar();
    void setupOverviewPage();
    void setupReceivePage();
    void setupSettingsPage();
    void setupLogsPage();
#ifdef ENABLE_SENDER
    void setupSendPage();
#endif
    void updateLocalIpDisplay();
    void selectSidebarItem(int pageIndex);

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
    InviteListener* m_inviteListener = nullptr;
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

    // Video window (separate from main window, like Mac app)
    VideoWindow* m_videoWindow = nullptr;

#ifdef ENABLE_SENDER
    // Send page
    QComboBox* m_receiverCombo = nullptr;
    QLineEdit* m_sendHostEdit = nullptr;
    uint16_t m_selectedReceiverPort = 51820;
    QSpinBox* m_fpsSpinBox = nullptr;
    QSpinBox* m_bitrateSpinBox = nullptr;
    QPushButton* m_sendBtn = nullptr;
    QPushButton* m_stopSendBtn = nullptr;
    QLabel* m_senderStatusLabel = nullptr;

    // Virtual Display (VDD) controls
    QComboBox* m_monitorCombo = nullptr;
    QComboBox* m_vddResolutionCombo = nullptr;
    QPushButton* m_createVddBtn = nullptr;
    QPushButton* m_removeVddBtn = nullptr;
    QPushButton* m_recheckVddBtn = nullptr;
    QLabel* m_vddStatusLabel = nullptr;
#endif
};
