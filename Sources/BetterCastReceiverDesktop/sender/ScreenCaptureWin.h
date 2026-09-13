#pragma once
// Note: this file is only compiled on Windows (gated in CMakeLists.txt).
// Do NOT wrap in #ifdef _WIN32 — AutoMoc cannot resolve preprocessor guards
// and will skip Q_OBJECT, causing linker errors.

#include "ScreenCapture.h"
#include <QTimer>
#include <QString>
#include <atomic>
#include <vector>
#include <cstdint>

// Forward declarations — avoid pulling Windows headers into every TU
struct ID3D11Device;
struct ID3D11DeviceContext;
struct ID3D11Texture2D;
struct IDXGIOutputDuplication;
struct HDC__;
typedef HDC__* HDC;
struct HBITMAP__;
typedef HBITMAP__* HBITMAP;

class ScreenCaptureWin : public ScreenCapture {
    Q_OBJECT
public:
    explicit ScreenCaptureWin(int targetFPS = 30, QObject* parent = nullptr);
    ~ScreenCaptureWin() override;

    // Set which monitor to capture (adapter + output index).
    // Must be called before start(). Default: adapter 0, output 0 (primary).
    void setMonitorIndex(int adapterIndex, int outputIndex);

    // Set the display device name for GDI fallback capture (e.g. "\\\\.\\DISPLAY17")
    void setDisplayName(const QString& name) { m_displayName = name; }

    bool start() override;
    void stop() override;
    bool isRunning() const override { return m_running; }
    QSize resolution() const override { return m_resolution; }

private:
    bool initD3D();
    bool initDuplication();
    bool initGdiFallback();
    void captureFrame();
    void captureFrameGdi();
    void cleanup();

    /// Draw the hardware cursor into a captured BGRA frame.
    ///
    /// Desktop Duplication hands back the desktop WITHOUT the pointer: Windows
    /// composites the normal cursor in a hardware overlay plane, which never
    /// reaches the duplicated surface. That is why the cursor appears while a
    /// window is being dragged (Windows falls back to drawing it in software,
    /// so it lands in the image) and vanishes the moment the drag ends.
    void compositePointer(uint8_t* bgra, int pitch, int w, int h);

    // D3D11 objects
    ID3D11Device* m_device = nullptr;
    ID3D11DeviceContext* m_context = nullptr;
    IDXGIOutputDuplication* m_duplication = nullptr;
    ID3D11Texture2D* m_stagingTex = nullptr;

    // GDI fallback objects
    HDC m_gdiDC = nullptr;
    HDC m_memDC = nullptr;
    HBITMAP m_bitmap = nullptr;
    bool m_useGdiFallback = false;

    QTimer m_timer;
    int m_targetFPS;
    int m_adapterIndex = 0;
    int m_outputIndex = 0;
    QString m_displayName;
    QSize m_resolution;
    std::atomic<bool> m_running{false};

    // Cursor state, carried between frames. Both halves have to be cached:
    // the position is only meaningful on frames where the mouse moved, and the
    // shape is only delivered when it CHANGES, not every frame.
    std::vector<uint8_t> m_ptrShape;
    int  m_ptrShapeType = 0;          // DXGI_OUTDUPL_POINTER_SHAPE_TYPE_*
    int  m_ptrWidth  = 0;
    int  m_ptrHeight = 0;             // for MONOCHROME this counts BOTH masks
    int  m_ptrPitch  = 0;
    int  m_ptrX = 0;
    int  m_ptrY = 0;
    bool m_ptrVisible = false;

    // Virtual-desktop origin of the GDI-captured display, so a cursor position
    // reported in desktop coordinates can be made relative to the capture.
    int m_gdiOriginX = 0;
    int m_gdiOriginY = 0;
};
