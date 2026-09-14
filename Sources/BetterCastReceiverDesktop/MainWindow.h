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
#include <QPixmap>
#include <QSize>
#include <QMouseEvent>
#include <QStringList>
#include <QTime>
#include <QFile>
#include <QDir>
#include <QStandardPaths>

#include "LogManager.h"

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
class DisplayArrangement;
#ifdef ENABLE_SENDER
class SenderController;
class VirtualDisplayVDD;
#endif

#ifdef _WIN32
class HotspotManager;
#endif

class UpdateChecker;
#ifdef _WIN32
class GlassBackdrop;
#endif

class MainWindow : public QMainWindow {
    Q_OBJECT

public:
    explicit MainWindow(QWidget* parent = nullptr);
    ~MainWindow();

#ifdef _WIN32
protected:
    // Glass mode paints a blurred snapshot of the desktop behind the window as
    // the window's own background. Being opaque it also clears the backing
    // store every frame, which the translucent approach never did — that is
    // what left each page of the stack drawn over the last.
    void paintEvent(QPaintEvent* event) override;
    void moveEvent(QMoveEvent* event) override;
    void resizeEvent(QResizeEvent* event) override;
public:
#endif

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
    // Warns before the one-time display setup blanks the screens. False if the
    // user cancelled, in which case nothing is started.
    bool confirmDisplaySetup();
    void onExtendDisplays();
    void onDeviceRowSelected(const QString& deviceName);
    void onRefreshMonitors();
    void onMonitorSelected(int index);
#endif

private:
    // A receiver we have discovered or connected to. The macOS sidebar lists
    // devices rather than fixed pages, so the Windows sidebar needs the same
    // model to be rebuilt as devices come and go.
    struct DeviceEntry {
        QString name;
        QString host;
        uint16_t port = 51820;
        bool connected = false;
        // Stream settings belong to the device, not the app: a phone on WiFi and
        // a laptop on ethernet want different rates, and one global pair of
        // spinboxes cannot express that. Seeded from the Send page defaults the
        // first time a device is seen, then owned by that device.
        int fps = 60;
        int bitrateMbps = 20;
        // 0x0 means "match this PC's primary display", which is what a virtual
        // screen should default to. A phone often wants something smaller.
        int width = 0;
        int height = 0;
        bool settingsCustomised = false;
    };
    QVector<DeviceEntry> m_devices;
    QString m_selectedDeviceName;   // empty when a fixed page is selected

    void setupUi();
    void applyTheme();       // rebuild the stylesheet for the current OS theme
    void maybeShowSupportPrompt();   // occasional, dismissible donation nudge
    void setupSidebar();
    void rebuildSidebar();          // re-run whenever the device list changes
    void setupDevicePage();
    void populateDevicePage(const DeviceEntry& device);
    int  indexOfDevice(const QString& name) const;
    void setupOverviewPage();
    void setupReceivePage();
    void setupSettingsPage();
#ifdef _WIN32
    void setupHotspotPage();
    void refreshHotspotUi();
#endif
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
#endif

    // Layout
    QSplitter* m_splitter = nullptr;
    QListWidget* m_sidebarList = nullptr;
    QStackedWidget* m_stack = nullptr;
    QLineEdit*      m_deviceFilter = nullptr;   // top-bar device search

#ifdef _WIN32
    GlassBackdrop* m_backdrop      = nullptr;
    QPixmap        m_backdropPixmap;
    QTimer*        m_backdropTimer = nullptr;
    bool           m_glassActive   = false;
    void refreshBackdrop();
#endif

    // GitHub Releases update check, same source of truth as the macOS app.
    UpdateChecker* m_updateChecker = nullptr;
    QLabel*        m_updateLabel   = nullptr;
    QPushButton*   m_updateBtn     = nullptr;
    QString        m_updateUrl;

#ifdef _WIN32
    // Wi-Fi hotspot pairing page. Windows-only: Mobile Hotspot is a WinRT
    // feature and there is no equivalent to expose elsewhere.
    int              m_pageHotspot   = -1;
    HotspotManager*  m_hotspot       = nullptr;
    QTimer*          m_hotspotTimer  = nullptr;
    bool             m_hotspotWanted = false;   // user asked for it; keep it alive
    QLabel*          m_hsStatus      = nullptr;
    QLabel*          m_hsDetail      = nullptr;
    QLabel*          m_hsQr          = nullptr;
    QLabel*          m_hsCaption     = nullptr;
    QPushButton*     m_hsToggle      = nullptr;
#endif

    // Page indices (set during setupUi based on ENABLE_SENDER)
    int m_pageOverview = -1;
    int m_pageSend = -1;     // only if ENABLE_SENDER
    int m_pageReceive = -1;
    int m_pageSettings = -1;
    int m_pageLogs = -1;
    int m_pageDevice = -1;   // per-device detail, repopulated on selection

    // Per-device detail page widgets
    QWidget* m_devicePageBody = nullptr;
    QLabel* m_deviceTitleLabel = nullptr;
    QLabel* m_deviceSubtitleLabel = nullptr;

    // Overview page
    DisplayArrangement* m_arrangement = nullptr;
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
    QComboBox* m_themeCombo = nullptr;   // Follow system / Light / Dark

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
    QComboBox* m_topologyCombo = nullptr;   // Extend / Duplicate / single-screen
    QPushButton* m_applyTopologyBtn = nullptr;
    QPushButton* m_recheckVddBtn = nullptr;
    QLabel* m_vddStatusLabel = nullptr;
#endif
};
