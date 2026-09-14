#pragma once
// Note: this file is only compiled on Windows (gated in CMakeLists.txt).
// Do NOT wrap in #ifdef _WIN32 — AutoMoc cannot resolve preprocessor guards
// and will skip Q_OBJECT, causing linker errors.

#include "ScreenCapture.h"
#include <QString>
#include <atomic>
#include <cstdint>
#include <thread>
#include <vector>

// Forward declarations — avoid pulling Windows headers into every TU
struct ID3D11Device;
struct ID3D11DeviceContext;
struct ID3D11Texture2D;
struct IDXGIOutputDuplication;
struct DXGI_OUTDUPL_FRAME_INFO;
struct HDC__;
typedef HDC__* HDC;
struct HBITMAP__;
typedef HBITMAP__* HBITMAP;

// DXGI Desktop Duplication capture.
//
// Runs a dedicated thread that blocks in AcquireNextFrame and wakes the instant
// Windows composites a new frame — the equivalent of ScreenCaptureKit's push
// callback on macOS. Polling on a timer instead costs up to a full frame
// interval of latency and jitters with the ~15.6ms Windows tick.
class ScreenCaptureWin : public ScreenCapture {
    Q_OBJECT
public:
    explicit ScreenCaptureWin(int targetFPS = 30, QObject* parent = nullptr);
    ~ScreenCaptureWin() override;

    // Preferred monitor as DXGI indices. Only used as a fallback when the
    // display name is empty or cannot be matched — indices are fragile because
    // a root-enumerated virtual display lives on its own adapter.
    void setMonitorIndex(int adapterIndex, int outputIndex);

    // Display device name, e.g. "\\\\.\\DISPLAY3". This is the reliable key:
    // it is matched against DXGI_OUTPUT_DESC.DeviceName across every adapter.
    void setDisplayName(const QString& name) { m_displayName = name; }

    bool start() override;
    void stop() override;             // stops and joins the capture thread
    bool isRunning() const override { return m_running; }
    QSize resolution() const override { return m_resolution; }

    // True when DXGI duplication was unavailable and GDI BitBlt is in use.
    // GDI has no dirty-rect info and reads back the full uncompressed surface,
    // so it is markedly slower — worth surfacing rather than failing silently.
    bool usingGdiFallback() const { return m_useGdiFallback; }

private:
    bool initD3DForOutput();          // resolve output by name, device on its adapter
    bool initDuplication();
    bool initGdiFallback();
    void captureLoop();               // runs on m_thread
    bool captureFrameDxgi();          // one blocking acquire + convert + emit
    void captureFrameGdi();
    void convertAndEmit(const uint8_t* bgra, int pitch, qint64 ptsNanos);
    void cleanup();

    // Desktop Duplication hands back the desktop WITHOUT the pointer: Windows
    // draws the normal cursor in a hardware overlay plane, which never reaches
    // the duplicated surface. That is why the cursor appears while a window is
    // being dragged (Windows falls back to a software cursor, so it lands in
    // the image) and vanishes the moment the drag ends. (#60)

    /// Cache the pointer position and shape carried by an acquired frame. Must
    /// run before ReleaseFrame(). Returns true when what the receiver should
    /// see changed: the cursor moved, changed shape, or was shown or hidden.
    bool updatePointer(const DXGI_OUTDUPL_FRAME_INFO& frameInfo);

    /// Draw the cached pointer into a captured BGRA frame, clipped to it.
    void compositePointer(uint8_t* bgra, int pitch, int w, int h);

    /// Staging textures are mapped again for pointer-only frames without a
    /// fresh copy of the desktop, so the pixels under the cursor are saved
    /// before compositing and put back after encoding.
    void savePointerArea(const uint8_t* bgra, int pitch, int w, int h);
    void restorePointerArea(uint8_t* bgra, int pitch);

    // D3D11 objects
    ID3D11Device* m_device = nullptr;
    ID3D11DeviceContext* m_context = nullptr;
    IDXGIOutputDuplication* m_duplication = nullptr;

    // Two staging textures, alternated per frame. Mapping the same texture that
    // was just written forces a CPU/GPU sync every frame; rotating avoids it.
    static constexpr int kStagingCount = 2;
    ID3D11Texture2D* m_stagingTex[kStagingCount] = {};
    int m_stagingIndex = 0;
    // False until a desktop image has been copied into staging since the last
    // (re)initialisation. Until then a pointer-only frame has nothing to draw on.
    bool m_haveDesktop = false;

    // GDI fallback objects
    HDC m_gdiDC = nullptr;
    HDC m_memDC = nullptr;
    HBITMAP m_bitmap = nullptr;
    bool m_useGdiFallback = false;

    // Repeat the last frame after this long with no desktop change, so an idle
    // screen does not look like a frozen stream to a receiver.
    static constexpr qint64 kKeepAliveIntervalNs = 1000000000LL;  // 1s

    std::thread m_thread;
    int m_targetFPS;
    qint64 m_minFrameIntervalNs = 0;  // rate limit; 0 = uncapped
    qint64 m_lastEmitNs = 0;
    int m_adapterIndex = 0;
    int m_outputIndex = 0;
    QString m_displayName;
    QSize m_resolution;
    std::atomic<bool> m_running{false};

    // Reused frame buffer — avoids a fresh allocation every frame
    QByteArray m_nv12;

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

    // Pixels under the composited cursor, restored after encoding.
    std::vector<uint8_t> m_ptrSaved;
    int m_ptrSavedX = 0;
    int m_ptrSavedY = 0;
    int m_ptrSavedW = 0;              // 0 = nothing saved
    int m_ptrSavedH = 0;

    // Virtual-desktop origin of the GDI-captured display, so a cursor position
    // reported in desktop coordinates can be made relative to the capture.
    int m_gdiOriginX = 0;
    int m_gdiOriginY = 0;
};
