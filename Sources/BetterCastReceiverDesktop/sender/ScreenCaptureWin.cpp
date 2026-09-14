#include "ScreenCaptureWin.h"
#include "../LogManager.h"

#include <d3d11.h>
#include <dxgi1_2.h>
#include <dxgi1_5.h>   // IDXGIOutput5::DuplicateOutput1
#include <Windows.h>
#include <timeapi.h>   // timeBeginPeriod — not pulled in when WIN32_LEAN_AND_MEAN is set
#include <QDebug>
#include <algorithm>
#include <chrono>
#include <cstring>

#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "gdi32.lib")
#pragma comment(lib, "winmm.lib")   // timeBeginPeriod
#pragma comment(lib, "user32.lib")  // GetCursorInfo / GetIconInfo / DrawIconEx for the GDI cursor

namespace {

qint64 nowNanos() {
    using namespace std::chrono;
    return duration_cast<nanoseconds>(steady_clock::now().time_since_epoch()).count();
}

} // namespace

ScreenCaptureWin::ScreenCaptureWin(int targetFPS, QObject* parent)
    : ScreenCapture(parent)
    , m_targetFPS(targetFPS > 0 ? targetFPS : 30)
{
    m_minFrameIntervalNs = 1000000000LL / m_targetFPS;
}

void ScreenCaptureWin::setMonitorIndex(int adapterIndex, int outputIndex) {
    m_adapterIndex = adapterIndex;
    m_outputIndex = outputIndex;
}

ScreenCaptureWin::~ScreenCaptureWin() {
    stop();
}

// Resolve the target monitor by device name across every adapter, then create
// the D3D11 device on the adapter that actually owns it.
//
// Index-based lookup is unreliable here: a VDD is root-enumerated (ROOT\DISPLAY)
// and shows up as its own DXGI adapter, so an index taken from a different
// enumeration points at the wrong adapter — DuplicateOutput then fails and we
// silently drop to the much slower GDI path.
bool ScreenCaptureWin::initD3DForOutput() {
    IDXGIFactory1* factory = nullptr;
    HRESULT hr = CreateDXGIFactory1(__uuidof(IDXGIFactory1), (void**)&factory);
    if (FAILED(hr)) {
        qWarning() << "Sender: CreateDXGIFactory1 failed";
        return false;
    }

    int foundAdapter = -1;
    int foundOutput = -1;

    if (!m_displayName.isEmpty()) {
        IDXGIAdapter1* adapter = nullptr;
        for (UINT a = 0; factory->EnumAdapters1(a, &adapter) != DXGI_ERROR_NOT_FOUND; a++) {
            IDXGIOutput* output = nullptr;
            for (UINT o = 0; adapter->EnumOutputs(o, &output) != DXGI_ERROR_NOT_FOUND; o++) {
                DXGI_OUTPUT_DESC desc;
                output->GetDesc(&desc);
                output->Release();

                if (m_displayName.compare(QString::fromWCharArray(desc.DeviceName),
                                          Qt::CaseInsensitive) == 0) {
                    foundAdapter = static_cast<int>(a);
                    foundOutput = static_cast<int>(o);
                    break;
                }
            }
            adapter->Release();
            if (foundAdapter >= 0) break;
        }
    }

    if (foundAdapter >= 0) {
        if (foundAdapter != m_adapterIndex || foundOutput != m_outputIndex) {
            LogManager::instance().log(
                QString("Sender: Resolved %1 to adapter %2 output %3 (was %4/%5)")
                    .arg(m_displayName).arg(foundAdapter).arg(foundOutput)
                    .arg(m_adapterIndex).arg(m_outputIndex));
        }
        m_adapterIndex = foundAdapter;
        m_outputIndex = foundOutput;
    } else if (!m_displayName.isEmpty()) {
        // Falling back to another adapter/output here would capture a DIFFERENT
        // monitor — in practice the primary, since the defaults are 0/0. That is
        // how a receiver ended up showing the main panel while the log claimed
        // it was streaming a virtual display. Refuse instead.
        factory->Release();
        LogManager::instance().log(
            QString("Sender: %1 is not in the DXGI enumeration — it is not attached "
                    "to the desktop, so there is nothing to capture.").arg(m_displayName));
        emit error(m_displayName + " is not attached to the desktop. Extend it in "
                                   "Display Settings, or pick another display.");
        return false;
    }

    IDXGIAdapter1* selectedAdapter = nullptr;
    hr = factory->EnumAdapters1(m_adapterIndex, &selectedAdapter);
    factory->Release();
    if (FAILED(hr)) {
        qWarning() << "Sender: Adapter" << m_adapterIndex << "not found, using default";
        selectedAdapter = nullptr;
    }

    UINT flags = 0;
#ifdef QT_DEBUG
    flags |= D3D11_CREATE_DEVICE_DEBUG;
#endif
    D3D_FEATURE_LEVEL featureLevel;
    hr = D3D11CreateDevice(
        selectedAdapter,
        selectedAdapter ? D3D_DRIVER_TYPE_UNKNOWN : D3D_DRIVER_TYPE_HARDWARE,
        nullptr, flags, nullptr, 0, D3D11_SDK_VERSION,
        &m_device, &featureLevel, &m_context);

    if (selectedAdapter) selectedAdapter->Release();

    if (FAILED(hr)) {
        qWarning() << "Sender: D3D11CreateDevice failed, hr=" << Qt::hex << hr;
        return false;
    }
    qDebug() << "Sender: D3D11 device on adapter" << m_adapterIndex
             << "feature level" << Qt::hex << featureLevel;
    return true;
}

bool ScreenCaptureWin::initDuplication() {
    IDXGIDevice* dxgiDevice = nullptr;
    HRESULT hr = m_device->QueryInterface(__uuidof(IDXGIDevice), (void**)&dxgiDevice);
    if (FAILED(hr)) { qWarning() << "Sender: QueryInterface IDXGIDevice failed"; return false; }

    IDXGIAdapter* adapter = nullptr;
    hr = dxgiDevice->GetAdapter(&adapter);
    dxgiDevice->Release();
    if (FAILED(hr)) { qWarning() << "Sender: GetAdapter failed"; return false; }

    IDXGIOutput* output = nullptr;
    hr = adapter->EnumOutputs(m_outputIndex, &output);
    adapter->Release();
    if (FAILED(hr)) {
        qWarning() << "Sender: EnumOutputs failed for output" << m_outputIndex;
        return false;
    }

    IDXGIOutput1* output1 = nullptr;
    hr = output->QueryInterface(__uuidof(IDXGIOutput1), (void**)&output1);
    if (FAILED(hr)) {
        output->Release();
        LogManager::instance().log("Sender: QueryInterface IDXGIOutput1 failed");
        return false;
    }
    // IDXGIOutput5 is only there on Windows 10 1703+; absent is fine.
    IDXGIOutput5* output5 = nullptr;
    output->QueryInterface(__uuidof(IDXGIOutput5), (void**)&output5);
    output->Release();

    // Mirroring the main screen fell back to GDI on a real machine ("DXGI
    // Desktop Duplication unavailable") while the virtual display on the same
    // GPU duplicated fine - and the only record of why was a qWarning nobody
    // could see. So: say why, in the log file; retry the refusals that are
    // commonly transient (a display that was just reconfigured, or another
    // duplication of this output still being torn down); and try
    // DuplicateOutput1, which some outputs accept when the legacy call does
    // not. Staging textures are BGRA either way.
    constexpr int kAttempts = 3;
    for (int attempt = 0; attempt < kAttempts && !m_duplication; attempt++) {
        if (attempt > 0) Sleep(300);

        hr = output1->DuplicateOutput(m_device, &m_duplication);
        if (SUCCEEDED(hr)) break;
        LogManager::instance().log(
            QString("Sender: DuplicateOutput on %1 failed (attempt %2, hr=0x%3)")
                .arg(m_displayName.isEmpty() ? QStringLiteral("primary") : m_displayName)
                .arg(attempt + 1).arg(static_cast<quint32>(hr), 8, 16, QChar('0')));

        if (output5) {
            const DXGI_FORMAT formats[] = {DXGI_FORMAT_B8G8R8A8_UNORM};
            HRESULT hr1 = output5->DuplicateOutput1(m_device, 0, 1, formats, &m_duplication);
            if (SUCCEEDED(hr1)) {
                LogManager::instance().log("Sender: DuplicateOutput1 succeeded where "
                                           "DuplicateOutput did not");
                hr = hr1;
                break;
            }
            LogManager::instance().log(
                QString("Sender: DuplicateOutput1 failed too (hr=0x%1)")
                    .arg(static_cast<quint32>(hr1), 8, 16, QChar('0')));
        }

        // Not worth retrying: unsupported stays unsupported.
        if (hr != DXGI_ERROR_NOT_CURRENTLY_AVAILABLE && hr != E_ACCESSDENIED) break;
    }
    if (output5) output5->Release();
    output1->Release();
    if (!m_duplication) {
        return false;
    }

    DXGI_OUTDUPL_DESC desc;
    m_duplication->GetDesc(&desc);
    m_resolution = QSize(desc.ModeDesc.Width, desc.ModeDesc.Height);
    qDebug() << "Sender: Desktop duplication ready," << m_resolution;

    // Rotating staging textures for CPU readback. Mapping the texture we just
    // wrote stalls the pipeline waiting on the GPU; alternating lets the copy
    // for frame N+1 proceed while frame N is being read.
    D3D11_TEXTURE2D_DESC texDesc = {};
    texDesc.Width = m_resolution.width();
    texDesc.Height = m_resolution.height();
    texDesc.MipLevels = 1;
    texDesc.ArraySize = 1;
    texDesc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    texDesc.SampleDesc.Count = 1;
    texDesc.Usage = D3D11_USAGE_STAGING;
    // WRITE as well as READ: the cursor is composited into the mapped texture
    // in place before the BGRA -> NV12 conversion, then taken back out.
    texDesc.CPUAccessFlags = D3D11_CPU_ACCESS_READ | D3D11_CPU_ACCESS_WRITE;

    for (int i = 0; i < kStagingCount; i++) {
        hr = m_device->CreateTexture2D(&texDesc, nullptr, &m_stagingTex[i]);
        if (FAILED(hr)) { qWarning() << "Sender: CreateTexture2D staging failed"; return false; }
    }
    m_stagingIndex = 0;
    m_haveDesktop = false;
    m_ptrSavedW = 0;
    return true;
}

bool ScreenCaptureWin::start() {
    if (m_running) return true;

    m_useGdiFallback = false;
    m_lastEmitNs = 0;

    if (!initD3DForOutput()) {
        LogManager::instance().log("Sender: D3D11 init failed, trying GDI fallback");
        cleanup();
        if (!initGdiFallback()) {
            emit error("Failed to initialize screen capture (both DXGI and GDI failed)");
            return false;
        }
    } else if (!initDuplication()) {
        LogManager::instance().log("Sender: DXGI Desktop Duplication unavailable, using GDI fallback");
        cleanup();
        if (!initGdiFallback()) {
            emit error("Failed to initialize screen capture (DXGI unsupported, GDI failed)");
            return false;
        }
    }

    m_running = true;
    m_thread = std::thread([this]() { captureLoop(); });

    if (m_useGdiFallback) {
        LogManager::instance().log(
            QString("Sender: Screen capture started (GDI fallback — expect higher latency) "
                    "at %1 FPS, %2x%3")
                .arg(m_targetFPS).arg(m_resolution.width()).arg(m_resolution.height()));
    } else {
        LogManager::instance().log(
            QString("Sender: Screen capture started (DXGI duplication) at %1 FPS, %2x%3")
                .arg(m_targetFPS).arg(m_resolution.width()).arg(m_resolution.height()));
    }
    return true;
}

void ScreenCaptureWin::stop() {
    m_running = false;                       // capture loop exits within its acquire timeout
    if (m_thread.joinable()) m_thread.join();
    cleanup();
}

void ScreenCaptureWin::captureLoop() {
    // Timer resolution affects our sleeps and DXGI's own wait granularity.
    timeBeginPeriod(1);

    while (m_running) {
        if (m_useGdiFallback) {
            const qint64 start = nowNanos();
            captureFrameGdi();
            const qint64 elapsed = nowNanos() - start;
            const qint64 remaining = m_minFrameIntervalNs - elapsed;
            if (remaining > 0 && m_running) {
                Sleep(static_cast<DWORD>(remaining / 1000000));
            }
        } else if (!captureFrameDxgi()) {
            break;
        }
    }

    timeEndPeriod(1);
}

// One iteration of the DXGI path. Returns false to terminate the loop.
bool ScreenCaptureWin::captureFrameDxgi() {
    if (!m_duplication) return false;

    bool havePending = false;   // a frame sits in staging, not yet converted

    while (m_running) {
        // Wait only as long as the pacing budget allows, so a pending frame
        // still gets emitted when the desktop goes idle mid-interval.
        DWORD timeoutMs = 100;
        if (havePending) {
            const qint64 due = m_lastEmitNs + m_minFrameIntervalNs;
            const qint64 waitNs = due - nowNanos();
            timeoutMs = waitNs <= 0 ? 0 : static_cast<DWORD>(waitNs / 1000000);
        }

        IDXGIResource* desktopResource = nullptr;
        DXGI_OUTDUPL_FRAME_INFO frameInfo = {};
        HRESULT hr = m_duplication->AcquireNextFrame(timeoutMs, &frameInfo, &desktopResource);

        if (hr == DXGI_ERROR_WAIT_TIMEOUT) {
            if (havePending) break;   // nothing newer coming — emit what we hold

            // Desktop genuinely idle. Skipping every unchanged frame saves a lot
            // of bitrate, but sending NOTHING means a receiver that joined during
            // a still moment shows blank or stale until something moves — which
            // reads as a frozen stream. Repeat the last frame about once a
            // second; static content compresses to almost nothing, so the cost
            // is negligible and the receiver stays in sync.
            const qint64 idleNs = nowNanos() - m_lastEmitNs;
            if (m_lastEmitNs != 0 && idleNs > kKeepAliveIntervalNs && !m_nv12.isEmpty()) {
                m_lastEmitNs = nowNanos();
                emit frameCaptured(m_nv12, m_resolution.width(), m_resolution.height(),
                                   m_lastEmitNs);
            }
            continue;
        }

        if (FAILED(hr)) {
            if (hr == DXGI_ERROR_ACCESS_LOST) {
                // Into the log file, not just qDebug: this is what a display
                // mode change, UAC prompt or Win+P does to a running capture,
                // and it is the prime suspect when receivers flicker.
                LogManager::instance().log(
                    QString("Sender: Desktop duplication lost on %1 — reinitializing")
                        .arg(m_displayName.isEmpty() ? QStringLiteral("primary") : m_displayName));
                if (m_duplication) { m_duplication->Release(); m_duplication = nullptr; }
                for (int i = 0; i < kStagingCount; i++) {
                    if (m_stagingTex[i]) { m_stagingTex[i]->Release(); m_stagingTex[i] = nullptr; }
                }
                if (!initDuplication()) {
                    emit error("Failed to reinitialize desktop duplication");
                    return false;
                }
                return true;
            }
            return false;
        }

        // The pointer rides along with the frame and has to be read while the
        // frame is still held.
        const bool pointerChanged = updatePointer(frameInfo);

        // LastPresentTime == 0 means the desktop image is unchanged. These used
        // to be dropped outright to save bitrate, but they are exactly the
        // frames where only the mouse moved — dropping them is what kept the
        // cursor frozen while hovering. Keep the ones that changed the pointer
        // and re-encode the newest staging texture, which still holds the
        // desktop; nothing needs copying. Pacing below still applies, so fast
        // mouse movement cannot spike the bitrate.
        if (frameInfo.LastPresentTime.QuadPart == 0) {
            if (desktopResource) desktopResource->Release();
            m_duplication->ReleaseFrame();
            if (!pointerChanged || !m_haveDesktop) continue;
            havePending = true;
            if (nowNanos() < m_lastEmitNs + m_minFrameIntervalNs) continue;
            break;
        }

        ID3D11Texture2D* desktopTex = nullptr;
        hr = desktopResource->QueryInterface(__uuidof(ID3D11Texture2D), (void**)&desktopTex);
        desktopResource->Release();
        if (FAILED(hr)) {
            m_duplication->ReleaseFrame();
            continue;
        }

        // Copy out and release promptly — holding the frame blocks compositing.
        m_stagingIndex = (m_stagingIndex + 1) % kStagingCount;
        m_context->CopyResource(m_stagingTex[m_stagingIndex], desktopTex);
        desktopTex->Release();
        m_duplication->ReleaseFrame();
        m_haveDesktop = true;
        havePending = true;

        // Under the frame budget? Keep draining so we encode only the newest
        // state instead of every intermediate frame of a fast animation.
        if (nowNanos() < m_lastEmitNs + m_minFrameIntervalNs) continue;
        break;
    }

    if (!havePending || !m_running) return m_running;

    ID3D11Texture2D* staging = m_stagingTex[m_stagingIndex];
    D3D11_MAPPED_SUBRESOURCE mapped;
    if (FAILED(m_context->Map(staging, 0, D3D11_MAP_READ_WRITE, 0, &mapped))) {
        return true;
    }
    const int w = m_resolution.width();
    const int h = m_resolution.height();
    auto* bgra = static_cast<uint8_t*>(mapped.pData);
    const int pitch = static_cast<int>(mapped.RowPitch);

    // A later pointer-only frame maps this same texture again without a fresh
    // desktop copy, so the cursor must not be left behind in it — otherwise it
    // smears a trail across the receiver as it moves.
    savePointerArea(bgra, pitch, w, h);
    compositePointer(bgra, pitch, w, h);
    convertAndEmit(bgra, pitch, nowNanos());
    restorePointerArea(bgra, pitch);

    m_context->Unmap(staging, 0);
    return true;
}

bool ScreenCaptureWin::updatePointer(const DXGI_OUTDUPL_FRAME_INFO& frameInfo) {
    bool changed = false;

    // PointerPosition is only valid on a frame where the mouse actually
    // updated. Reading it unconditionally parks the cursor at the top-left
    // corner on every other frame.
    if (frameInfo.LastMouseUpdateTime.QuadPart != 0) {
        const bool visible = frameInfo.PointerPosition.Visible != 0;
        const int x = frameInfo.PointerPosition.Position.x;
        const int y = frameInfo.PointerPosition.Position.y;
        // Hidden-to-hidden moves are the cursor travelling across ANOTHER
        // monitor; re-encoding this one for them would be wasted bitrate.
        if (visible != m_ptrVisible || (visible && (x != m_ptrX || y != m_ptrY))) {
            changed = true;
        }
        m_ptrVisible = visible;
        m_ptrX = x;
        m_ptrY = y;
    }

    // The shape arrives only when it changes, so it has to be kept. Asking for
    // it every frame returns nothing and the cursor flickers.
    if (frameInfo.PointerShapeBufferSize > 0) {
        m_ptrShape.resize(frameInfo.PointerShapeBufferSize);
        DXGI_OUTDUPL_POINTER_SHAPE_INFO shapeInfo = {};
        UINT required = 0;
        if (SUCCEEDED(m_duplication->GetFramePointerShape(
                static_cast<UINT>(m_ptrShape.size()), m_ptrShape.data(),
                &required, &shapeInfo))) {
            m_ptrShapeType = static_cast<int>(shapeInfo.Type);
            m_ptrWidth     = static_cast<int>(shapeInfo.Width);
            m_ptrHeight    = static_cast<int>(shapeInfo.Height);
            m_ptrPitch     = static_cast<int>(shapeInfo.Pitch);
        } else {
            m_ptrShape.clear();
        }
        if (m_ptrVisible) changed = true;
    }

    return changed;
}

void ScreenCaptureWin::savePointerArea(const uint8_t* bgra, int pitch, int w, int h) {
    m_ptrSavedW = 0;
    if (!m_ptrVisible || m_ptrShape.empty() || m_ptrWidth <= 0 || m_ptrHeight <= 0) return;

    const bool mono = (m_ptrShapeType == DXGI_OUTDUPL_POINTER_SHAPE_TYPE_MONOCHROME);
    const int ch = mono ? m_ptrHeight / 2 : m_ptrHeight;

    const int x0 = (std::max)(0, m_ptrX);
    const int y0 = (std::max)(0, m_ptrY);
    const int x1 = (std::min)(w, m_ptrX + m_ptrWidth);
    const int y1 = (std::min)(h, m_ptrY + ch);
    if (x1 <= x0 || y1 <= y0) return;

    const int rw = x1 - x0;
    const int rh = y1 - y0;
    m_ptrSaved.resize(static_cast<size_t>(rw) * rh * 4);
    for (int row = 0; row < rh; ++row) {
        memcpy(m_ptrSaved.data() + static_cast<size_t>(row) * rw * 4,
               bgra + static_cast<size_t>(y0 + row) * pitch + static_cast<size_t>(x0) * 4,
               static_cast<size_t>(rw) * 4);
    }
    m_ptrSavedX = x0;
    m_ptrSavedY = y0;
    m_ptrSavedW = rw;
    m_ptrSavedH = rh;
}

void ScreenCaptureWin::restorePointerArea(uint8_t* bgra, int pitch) {
    if (m_ptrSavedW <= 0) return;
    for (int row = 0; row < m_ptrSavedH; ++row) {
        memcpy(bgra + static_cast<size_t>(m_ptrSavedY + row) * pitch
                    + static_cast<size_t>(m_ptrSavedX) * 4,
               m_ptrSaved.data() + static_cast<size_t>(row) * m_ptrSavedW * 4,
               static_cast<size_t>(m_ptrSavedW) * 4);
    }
    m_ptrSavedW = 0;
}

void ScreenCaptureWin::compositePointer(uint8_t* bgra, int pitch, int w, int h) {
    if (!m_ptrVisible || m_ptrShape.empty() || m_ptrWidth <= 0 || m_ptrHeight <= 0) return;
    if (m_ptrPitch <= 0) return;

    // A monochrome pointer packs two 1bpp masks stacked vertically, so the
    // reported height covers both and the real cursor is half of it.
    const bool mono = (m_ptrShapeType == DXGI_OUTDUPL_POINTER_SHAPE_TYPE_MONOCHROME);
    const int ch = mono ? m_ptrHeight / 2 : m_ptrHeight;
    const int cw = m_ptrWidth;
    if (ch <= 0) return;

    const size_t shapeBytes = m_ptrShape.size();

    for (int row = 0; row < ch; ++row) {
        const int dy = m_ptrY + row;
        if (dy < 0 || dy >= h) continue;

        for (int col = 0; col < cw; ++col) {
            const int dx = m_ptrX + col;
            if (dx < 0 || dx >= w) continue;

            uint8_t* dst = bgra + static_cast<size_t>(dy) * pitch + static_cast<size_t>(dx) * 4;

            if (mono) {
                // AND mask first, XOR mask below it. Where AND is set the
                // background shows through, and XOR then inverts it — which is
                // how the I-beam stays visible over both light and dark text.
                const size_t andIdx = static_cast<size_t>(row) * m_ptrPitch + col / 8;
                const size_t xorIdx = static_cast<size_t>(row + ch) * m_ptrPitch + col / 8;
                if (xorIdx >= shapeBytes) continue;
                const uint8_t bit = 0x80 >> (col % 8);
                const bool andBit = (m_ptrShape[andIdx] & bit) != 0;
                const bool xorBit = (m_ptrShape[xorIdx] & bit) != 0;
                for (int c = 0; c < 3; ++c) {
                    uint8_t v = andBit ? dst[c] : 0;
                    if (xorBit) v = static_cast<uint8_t>(~v);
                    dst[c] = v;
                }
                continue;
            }

            const size_t srcIdx = static_cast<size_t>(row) * m_ptrPitch + static_cast<size_t>(col) * 4;
            if (srcIdx + 3 >= shapeBytes) continue;
            const uint8_t* src = m_ptrShape.data() + srcIdx;

            if (m_ptrShapeType == DXGI_OUTDUPL_POINTER_SHAPE_TYPE_MASKED_COLOR) {
                // Here the alpha byte is a flag rather than a blend factor:
                // 0 means replace the pixel, 0xFF means XOR it with the screen.
                if (src[3] == 0) {
                    dst[0] = src[0]; dst[1] = src[1]; dst[2] = src[2];
                } else {
                    dst[0] ^= src[0]; dst[1] ^= src[1]; dst[2] ^= src[2];
                }
            } else {
                // Ordinary colour pointer: straight alpha blend.
                const int a = src[3];
                if (a == 0) continue;
                if (a == 255) {
                    dst[0] = src[0]; dst[1] = src[1]; dst[2] = src[2];
                } else {
                    for (int c = 0; c < 3; ++c) {
                        dst[c] = static_cast<uint8_t>((src[c] * a + dst[c] * (255 - a)) / 255);
                    }
                }
            }
        }
    }
}

bool ScreenCaptureWin::initGdiFallback() {
    if (m_displayName.isEmpty()) {
        m_gdiDC = CreateDCA("DISPLAY", nullptr, nullptr, nullptr);
        if (!m_gdiDC) m_gdiDC = GetDC(nullptr);  // no target named — whole desktop is fine
    } else {
        m_gdiDC = CreateDCA(nullptr, m_displayName.toLocal8Bit().constData(), nullptr, nullptr);
        // Deliberately NOT falling back to GetDC(nullptr) here. That grabs the
        // whole virtual desktop, so asking for a display we cannot open used to
        // silently stream the primary panel instead — which looks exactly like
        // the receiver mirroring your main screen. Fail loudly instead.
        if (!m_gdiDC) {
            LogManager::instance().log(
                "Sender: Cannot open " + m_displayName +
                " for capture — it is most likely not attached to the desktop.");
            emit error(m_displayName + " is not attached to the desktop, so there is "
                                       "nothing to capture. Extend it in Display Settings, "
                                       "or let BetterCast attach it for you.");
            return false;
        }
    }
    if (!m_gdiDC) {
        LogManager::instance().log("Sender: GDI CreateDC failed");
        return false;
    }

    int w = GetDeviceCaps(m_gdiDC, HORZRES);
    int h = GetDeviceCaps(m_gdiDC, VERTRES);
    if (w <= 0 || h <= 0) {
        LogManager::instance().log(QString("Sender: GDI invalid resolution: %1x%2").arg(w).arg(h));
        DeleteDC(m_gdiDC);
        m_gdiDC = nullptr;
        return false;
    }

    m_memDC = CreateCompatibleDC(m_gdiDC);
    m_bitmap = CreateCompatibleBitmap(m_gdiDC, w, h);
    SelectObject(m_memDC, m_bitmap);

    // Where this display sits on the virtual desktop, so a cursor position
    // reported in desktop coordinates can be shifted into capture coordinates.
    // Left at the origin for the primary-display DC, which starts at 0,0.
    m_gdiOriginX = 0;
    m_gdiOriginY = 0;
    m_loggedGdiCursor = false;
    if (!m_displayName.isEmpty()) {
        DEVMODEA dm = {};
        dm.dmSize = sizeof(dm);
        if (EnumDisplaySettingsA(m_displayName.toLocal8Bit().constData(),
                                 ENUM_CURRENT_SETTINGS, &dm)
            && (dm.dmFields & DM_POSITION)) {
            m_gdiOriginX = dm.dmPosition.x;
            m_gdiOriginY = dm.dmPosition.y;
        }
    }

    m_resolution = QSize(w, h);
    m_useGdiFallback = true;

    LogManager::instance().log(QString("Sender: GDI capture initialized for %1 (%2x%3)")
                                   .arg(m_displayName.isEmpty() ? "primary" : m_displayName)
                                   .arg(w).arg(h));
    return true;
}

void ScreenCaptureWin::captureFrameGdi() {
    if (!m_running || !m_gdiDC || !m_memDC) return;

    const int w = m_resolution.width();
    const int h = m_resolution.height();

    BitBlt(m_memDC, 0, 0, w, h, m_gdiDC, 0, 0, SRCCOPY);

    // SRCCOPY leaves the cursor out as well, so draw it on. DrawIconEx handles
    // all the mask arithmetic that the duplication path has to do by hand, and
    // m_memDC is rebuilt by the next BitBlt, so nothing needs restoring.
    CURSORINFO ci = {};
    ci.cbSize = sizeof(ci);
    const BOOL haveCursorInfo = GetCursorInfo(&ci);
    const bool showing = haveCursorInfo && (ci.flags & CURSOR_SHOWING) && ci.hCursor;
    int cx = 0, cy = 0;
    BOOL drawn = FALSE;
    if (showing) {
        // The hotspot is only a refinement. The previous version skipped the
        // cursor entirely whenever GetIconInfo failed, which is one way a
        // mirrored screen could stream with no pointer at all.
        ICONINFO ii = {};
        const bool haveIconInfo = GetIconInfo(ci.hCursor, &ii) != FALSE;
        // ptScreenPos is in virtual-desktop coordinates; the DC starts at
        // this display's origin.
        cx = ci.ptScreenPos.x - m_gdiOriginX - (haveIconInfo ? static_cast<int>(ii.xHotspot) : 0);
        cy = ci.ptScreenPos.y - m_gdiOriginY - (haveIconInfo ? static_cast<int>(ii.yHotspot) : 0);
        drawn = DrawIconEx(m_memDC, cx, cy, ci.hCursor, 0, 0, 0, nullptr, DI_NORMAL);
        if (ii.hbmMask)  DeleteObject(ii.hbmMask);
        if (ii.hbmColor) DeleteObject(ii.hbmColor);
    }
    // Once per capture: enough to tell "no cursor" apart from "drawn off-frame".
    if (!m_loggedGdiCursor) {
        m_loggedGdiCursor = true;
        LogManager::instance().log(
            QString("Sender: GDI cursor — info=%1 showing=%2 screen=%3,%4 frame=%5,%6 "
                    "(%7x%8) drawn=%9")
                .arg(haveCursorInfo ? "yes" : "no", showing ? "yes" : "no")
                .arg(ci.ptScreenPos.x).arg(ci.ptScreenPos.y).arg(cx).arg(cy)
                .arg(w).arg(h).arg(drawn ? "yes" : "no"));
    }

    BITMAPINFOHEADER bi = {};
    bi.biSize = sizeof(bi);
    bi.biWidth = w;
    bi.biHeight = -h;  // top-down
    bi.biPlanes = 1;
    bi.biBitCount = 32;
    bi.biCompression = BI_RGB;

    QByteArray bgraData(w * h * 4, Qt::Uninitialized);
    GetDIBits(m_memDC, m_bitmap, 0, h, bgraData.data(),
              reinterpret_cast<BITMAPINFO*>(&bi), DIB_RGB_COLORS);

    convertAndEmit(reinterpret_cast<const uint8_t*>(bgraData.constData()), w * 4, nowNanos());
}

// BGRA → NV12 (BT.601). Runs on the capture thread, never the GUI thread.
void ScreenCaptureWin::convertAndEmit(const uint8_t* bgra, int pitch, qint64 ptsNanos) {
    const int w = m_resolution.width();
    const int h = m_resolution.height();
    if (w <= 0 || h <= 0 || !bgra) return;

    const int ySize = w * h;
    const int uvSize = w * (h / 2);
    if (m_nv12.size() != ySize + uvSize) {
        m_nv12.resize(ySize + uvSize);
    }
    uint8_t* yPlane = reinterpret_cast<uint8_t*>(m_nv12.data());
    uint8_t* uvPlane = yPlane + ySize;

    // Fused loop: Y for every pixel, UV from each 2x2 block.
    for (int y = 0; y < h; y += 2) {
        const uint8_t* row0 = bgra + y * pitch;
        const uint8_t* row1 = bgra + (y + 1) * pitch;
        uint8_t* yRow0 = yPlane + y * w;
        uint8_t* yRow1 = yPlane + (y + 1) * w;
        uint8_t* uvRow = uvPlane + (y / 2) * w;

        for (int x = 0; x < w; x += 2) {
            const int b00 = row0[x*4+0],     g00 = row0[x*4+1],     r00 = row0[x*4+2];
            const int b01 = row0[(x+1)*4+0], g01 = row0[(x+1)*4+1], r01 = row0[(x+1)*4+2];
            const int b10 = row1[x*4+0],     g10 = row1[x*4+1],     r10 = row1[x*4+2];
            const int b11 = row1[(x+1)*4+0], g11 = row1[(x+1)*4+1], r11 = row1[(x+1)*4+2];

            yRow0[x]   = static_cast<uint8_t>(((66*r00 + 129*g00 + 25*b00 + 128) >> 8) + 16);
            yRow0[x+1] = static_cast<uint8_t>(((66*r01 + 129*g01 + 25*b01 + 128) >> 8) + 16);
            yRow1[x]   = static_cast<uint8_t>(((66*r10 + 129*g10 + 25*b10 + 128) >> 8) + 16);
            yRow1[x+1] = static_cast<uint8_t>(((66*r11 + 129*g11 + 25*b11 + 128) >> 8) + 16);

            const int rAvg = (r00 + r01 + r10 + r11) >> 2;
            const int gAvg = (g00 + g01 + g10 + g11) >> 2;
            const int bAvg = (b00 + b01 + b10 + b11) >> 2;
            uvRow[x]   = static_cast<uint8_t>(((-38*rAvg - 74*gAvg + 112*bAvg + 128) >> 8) + 128);
            uvRow[x+1] = static_cast<uint8_t>(((112*rAvg - 94*gAvg - 18*bAvg + 128) >> 8) + 128);
        }
    }

    m_lastEmitNs = ptsNanos;
    emit frameCaptured(m_nv12, w, h, ptsNanos);
}

void ScreenCaptureWin::cleanup() {
    if (m_duplication) { m_duplication->Release(); m_duplication = nullptr; }
    for (int i = 0; i < kStagingCount; i++) {
        if (m_stagingTex[i]) { m_stagingTex[i]->Release(); m_stagingTex[i] = nullptr; }
    }
    if (m_context)     { m_context->Release();     m_context = nullptr; }
    if (m_device)      { m_device->Release();      m_device = nullptr; }
    if (m_bitmap)      { DeleteObject(m_bitmap);   m_bitmap = nullptr; }
    if (m_memDC)       { DeleteDC(m_memDC);        m_memDC = nullptr; }
    if (m_gdiDC)       { DeleteDC(m_gdiDC);        m_gdiDC = nullptr; }
    m_useGdiFallback = false;
    m_resolution = QSize();
}
