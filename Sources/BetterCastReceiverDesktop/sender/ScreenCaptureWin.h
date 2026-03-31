#pragma once
// Note: this file is only compiled on Windows (gated in CMakeLists.txt).
// Do NOT wrap in #ifdef _WIN32 — AutoMoc cannot resolve preprocessor guards
// and will skip Q_OBJECT, causing linker errors.

#include "ScreenCapture.h"
#include <QTimer>
#include <atomic>

// Forward declarations — avoid pulling Windows headers into every TU
struct ID3D11Device;
struct ID3D11DeviceContext;
struct ID3D11Texture2D;
struct IDXGIOutputDuplication;

class ScreenCaptureWin : public ScreenCapture {
    Q_OBJECT
public:
    explicit ScreenCaptureWin(int targetFPS = 30, QObject* parent = nullptr);
    ~ScreenCaptureWin() override;

    // Set which monitor to capture (adapter + output index).
    // Must be called before start(). Default: adapter 0, output 0 (primary).
    void setMonitorIndex(int adapterIndex, int outputIndex);

    bool start() override;
    void stop() override;
    bool isRunning() const override { return m_running; }
    QSize resolution() const override { return m_resolution; }

private:
    bool initD3D();
    bool initDuplication();
    void captureFrame();
    void cleanup();

    // D3D11 objects
    ID3D11Device* m_device = nullptr;
    ID3D11DeviceContext* m_context = nullptr;
    IDXGIOutputDuplication* m_duplication = nullptr;
    ID3D11Texture2D* m_stagingTex = nullptr;

    QTimer m_timer;
    int m_targetFPS;
    int m_adapterIndex = 0;
    int m_outputIndex = 0;
    QSize m_resolution;
    std::atomic<bool> m_running{false};
};
