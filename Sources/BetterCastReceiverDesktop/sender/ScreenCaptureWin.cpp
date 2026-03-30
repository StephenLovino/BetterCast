#include "ScreenCaptureWin.h"

#include <d3d11.h>
#include <dxgi1_2.h>
#include <QDebug>

#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")

ScreenCaptureWin::ScreenCaptureWin(int targetFPS, QObject* parent)
    : ScreenCapture(parent)
    , m_targetFPS(targetFPS)
{
    connect(&m_timer, &QTimer::timeout, this, &ScreenCaptureWin::captureFrame);
}

ScreenCaptureWin::~ScreenCaptureWin() {
    stop();
}

bool ScreenCaptureWin::initD3D() {
    D3D_FEATURE_LEVEL featureLevel;
    UINT flags = 0;
#ifdef QT_DEBUG
    flags |= D3D11_CREATE_DEVICE_DEBUG;
#endif

    HRESULT hr = D3D11CreateDevice(
        nullptr,                    // default adapter
        D3D_DRIVER_TYPE_HARDWARE,
        nullptr,
        flags,
        nullptr, 0,                 // default feature levels
        D3D11_SDK_VERSION,
        &m_device,
        &featureLevel,
        &m_context
    );

    if (FAILED(hr)) {
        qWarning() << "Sender: D3D11CreateDevice failed, hr=" << Qt::hex << hr;
        return false;
    }
    qDebug() << "Sender: D3D11 device created, feature level:" << Qt::hex << featureLevel;
    return true;
}

bool ScreenCaptureWin::initDuplication() {
    // Get DXGI device → adapter → output → output1 → duplicate
    IDXGIDevice* dxgiDevice = nullptr;
    HRESULT hr = m_device->QueryInterface(__uuidof(IDXGIDevice), (void**)&dxgiDevice);
    if (FAILED(hr)) { qWarning() << "Sender: QueryInterface IDXGIDevice failed"; return false; }

    IDXGIAdapter* adapter = nullptr;
    hr = dxgiDevice->GetAdapter(&adapter);
    dxgiDevice->Release();
    if (FAILED(hr)) { qWarning() << "Sender: GetAdapter failed"; return false; }

    IDXGIOutput* output = nullptr;
    hr = adapter->EnumOutputs(0, &output);  // primary monitor
    adapter->Release();
    if (FAILED(hr)) { qWarning() << "Sender: EnumOutputs failed — no monitor?"; return false; }

    IDXGIOutput1* output1 = nullptr;
    hr = output->QueryInterface(__uuidof(IDXGIOutput1), (void**)&output1);
    output->Release();
    if (FAILED(hr)) { qWarning() << "Sender: QueryInterface IDXGIOutput1 failed"; return false; }

    hr = output1->DuplicateOutput(m_device, &m_duplication);
    output1->Release();
    if (FAILED(hr)) {
        qWarning() << "Sender: DuplicateOutput failed, hr=" << Qt::hex << hr;
        return false;
    }

    // Get desktop dimensions
    DXGI_OUTDUPL_DESC desc;
    m_duplication->GetDesc(&desc);
    m_resolution = QSize(desc.ModeDesc.Width, desc.ModeDesc.Height);
    qDebug() << "Sender: Desktop duplication ready," << m_resolution;

    // Create staging texture for CPU readback (BGRA → we'll convert to NV12)
    D3D11_TEXTURE2D_DESC texDesc = {};
    texDesc.Width = m_resolution.width();
    texDesc.Height = m_resolution.height();
    texDesc.MipLevels = 1;
    texDesc.ArraySize = 1;
    texDesc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    texDesc.SampleDesc.Count = 1;
    texDesc.Usage = D3D11_USAGE_STAGING;
    texDesc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;

    hr = m_device->CreateTexture2D(&texDesc, nullptr, &m_stagingTex);
    if (FAILED(hr)) { qWarning() << "Sender: CreateTexture2D staging failed"; return false; }

    return true;
}

bool ScreenCaptureWin::start() {
    if (m_running) return true;

    if (!initD3D()) {
        emit error("Failed to initialize Direct3D 11");
        return false;
    }
    if (!initDuplication()) {
        emit error("Failed to initialize DXGI Desktop Duplication");
        cleanup();
        return false;
    }

    m_running = true;
    m_timer.start(1000 / m_targetFPS);
    qDebug() << "Sender: Screen capture started at" << m_targetFPS << "FPS";
    return true;
}

void ScreenCaptureWin::stop() {
    m_running = false;
    m_timer.stop();
    cleanup();
}

void ScreenCaptureWin::captureFrame() {
    if (!m_running || !m_duplication) return;

    IDXGIResource* desktopResource = nullptr;
    DXGI_OUTDUPL_FRAME_INFO frameInfo;

    HRESULT hr = m_duplication->AcquireNextFrame(0, &frameInfo, &desktopResource);
    if (hr == DXGI_ERROR_WAIT_TIMEOUT) {
        return; // No new frame — desktop unchanged
    }
    if (FAILED(hr)) {
        if (hr == DXGI_ERROR_ACCESS_LOST) {
            qDebug() << "Sender: Desktop duplication access lost, reinitializing...";
            if (m_duplication) { m_duplication->Release(); m_duplication = nullptr; }
            if (m_stagingTex) { m_stagingTex->Release(); m_stagingTex = nullptr; }
            if (!initDuplication()) {
                emit error("Failed to reinitialize desktop duplication");
                stop();
            }
        }
        return;
    }

    // Copy desktop texture to staging texture for CPU read
    ID3D11Texture2D* desktopTex = nullptr;
    hr = desktopResource->QueryInterface(__uuidof(ID3D11Texture2D), (void**)&desktopTex);
    desktopResource->Release();
    if (FAILED(hr)) {
        m_duplication->ReleaseFrame();
        return;
    }

    m_context->CopyResource(m_stagingTex, desktopTex);
    desktopTex->Release();
    m_duplication->ReleaseFrame();

    // Map staging texture and convert BGRA → NV12
    D3D11_MAPPED_SUBRESOURCE mapped;
    hr = m_context->Map(m_stagingTex, 0, D3D11_MAP_READ, 0, &mapped);
    if (FAILED(hr)) return;

    int w = m_resolution.width();
    int h = m_resolution.height();
    const uint8_t* bgra = static_cast<const uint8_t*>(mapped.pData);
    int pitch = mapped.RowPitch;

    // NV12: Y plane (w*h) + UV plane (w*h/2), interleaved U/V
    int ySize = w * h;
    int uvSize = w * (h / 2);
    QByteArray nv12(ySize + uvSize, Qt::Uninitialized);
    uint8_t* yPlane = reinterpret_cast<uint8_t*>(nv12.data());
    uint8_t* uvPlane = yPlane + ySize;

    // BGRA → NV12 conversion (BT.601)
    // Combined pass: compute Y for every pixel, UV for even rows/cols
    // Fused loop avoids iterating over the frame twice
    for (int y = 0; y < h; y += 2) {
        const uint8_t* row0 = bgra + y * pitch;
        const uint8_t* row1 = bgra + (y + 1) * pitch;
        uint8_t* yRow0 = yPlane + y * w;
        uint8_t* yRow1 = yPlane + (y + 1) * w;
        uint8_t* uvRow = uvPlane + (y / 2) * w;

        for (int x = 0; x < w; x += 2) {
            // Top-left pixel
            int b00 = row0[x*4+0], g00 = row0[x*4+1], r00 = row0[x*4+2];
            // Top-right pixel
            int b01 = row0[(x+1)*4+0], g01 = row0[(x+1)*4+1], r01 = row0[(x+1)*4+2];
            // Bottom-left pixel
            int b10 = row1[x*4+0], g10 = row1[x*4+1], r10 = row1[x*4+2];
            // Bottom-right pixel
            int b11 = row1[(x+1)*4+0], g11 = row1[(x+1)*4+1], r11 = row1[(x+1)*4+2];

            // Y for all 4 pixels
            yRow0[x]   = static_cast<uint8_t>(((66*r00 + 129*g00 + 25*b00 + 128) >> 8) + 16);
            yRow0[x+1] = static_cast<uint8_t>(((66*r01 + 129*g01 + 25*b01 + 128) >> 8) + 16);
            yRow1[x]   = static_cast<uint8_t>(((66*r10 + 129*g10 + 25*b10 + 128) >> 8) + 16);
            yRow1[x+1] = static_cast<uint8_t>(((66*r11 + 129*g11 + 25*b11 + 128) >> 8) + 16);

            // UV from 2x2 average
            int rAvg = (r00 + r01 + r10 + r11) >> 2;
            int gAvg = (g00 + g01 + g10 + g11) >> 2;
            int bAvg = (b00 + b01 + b10 + b11) >> 2;
            uvRow[x]   = static_cast<uint8_t>(((-38*rAvg - 74*gAvg + 112*bAvg + 128) >> 8) + 128);
            uvRow[x+1] = static_cast<uint8_t>(((112*rAvg - 94*gAvg - 18*bAvg + 128) >> 8) + 128);
        }
    }

    m_context->Unmap(m_stagingTex, 0);

    emit frameCaptured(nv12, w, h);
}

void ScreenCaptureWin::cleanup() {
    if (m_duplication) { m_duplication->Release(); m_duplication = nullptr; }
    if (m_stagingTex)  { m_stagingTex->Release();  m_stagingTex = nullptr; }
    if (m_context)     { m_context->Release();     m_context = nullptr; }
    if (m_device)      { m_device->Release();      m_device = nullptr; }
    m_resolution = QSize();
}
