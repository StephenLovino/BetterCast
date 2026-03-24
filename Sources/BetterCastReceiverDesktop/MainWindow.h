#pragma once

#include <QMainWindow>
#include <QLabel>
#include <QLineEdit>
#include <QPushButton>
#include <QStackedWidget>
#include <QSize>

class VideoRenderer;
class VideoDecoder;
class NetworkListener;
class InputHandler;
class ServiceDiscovery;

class MainWindow : public QMainWindow {
    Q_OBJECT

public:
    explicit MainWindow(QWidget* parent = nullptr);
    ~MainWindow();

private slots:
    void onConnectClicked();
    void onConnectionEstablished();
    void onConnectionLost();
    void onStatusChanged(const QString& status);
    void onVideoSizeChanged(QSize size);

private:
    void setupUi();
    void resizeToFitVideo(int videoWidth, int videoHeight);
    void updateLocalIpDisplay();

    // Core components
    VideoDecoder* m_decoder = nullptr;
    VideoRenderer* m_renderer = nullptr;
    NetworkListener* m_network = nullptr;
    InputHandler* m_inputHandler = nullptr;
    ServiceDiscovery* m_discovery = nullptr;

    // UI
    QStackedWidget* m_stack = nullptr;
    QWidget* m_connectPage = nullptr;
    QLineEdit* m_hostEdit = nullptr;
    QLineEdit* m_portEdit = nullptr;
    QPushButton* m_connectBtn = nullptr;
    QLabel* m_statusLabel = nullptr;
    QLabel* m_ipLabel = nullptr;
};
