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
    // Y plane: full resolution
    for (int y = 0; y < h; y++) {
        const uint8_t* row = bgra + y * pitch;
        uint8_t* yRow = yPlane + y * w;
        for (int x = 0; x < w; x++) {
            uint8_t b = row[x * 4 + 0];
            uint8_t g = row[x * 4 + 1];
            uint8_t r = row[x * 4 + 2];
            // BT.601: Y = 0.299*R + 0.587*G + 0.114*B
            yRow[x] = static_cast<uint8_t>((66 * r + 129 * g + 25 * b + 128) >> 8) + 16;
        }
    }

    // UV plane: half resolution, subsample 2x2 blocks
    for (int y = 0; y < h; y += 2) {
        const uint8_t* row0 = bgra + y * pitch;
        const uint8_t* row1 = bgra + (y + 1) * pitch;
        uint8_t* uvRow = uvPlane + (y / 2) * w;
        for (int x = 0; x < w; x += 2) {
            // Average 2x2 block
            int r = (row0[x*4+2] + row0[(x+1)*4+2] + row1[x*4+2] + row1[(x+1)*4+2]) >> 2;
            int g = (row0[x*4+1] + row0[(x+1)*4+1] + row1[x*4+1] + row1[(x+1)*4+1]) >> 2;
            int b = (row0[x*4+0] + row0[(x+1)*4+0] + row1[x*4+0] + row1[(x+1)*4+0]) >> 2;
            // BT.601: Cb = -0.169*R - 0.331*G + 0.500*B + 128
            //         Cr =  0.500*R - 0.419*G - 0.081*B + 128
            uvRow[x]     = static_cast<uint8_t>(((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128);
            uvRow[x + 1] = static_cast<uint8_t>(((112 * r - 94 * g - 18 * b + 128) >> 8) + 128);
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
