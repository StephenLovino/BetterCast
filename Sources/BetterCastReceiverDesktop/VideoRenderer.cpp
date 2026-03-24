#include "VideoRenderer.h"
#include <QDebug>

extern "C" {
#include <libavutil/frame.h>
}

// Vertex data: position (x,y) + texcoord (u,v)
static const float kVertexData[] = {
    // pos      // tex
    -1.0f,  1.0f,  0.0f, 0.0f,  // top-left
    -1.0f, -1.0f,  0.0f, 1.0f,  // bottom-left
     1.0f,  1.0f,  1.0f, 0.0f,  // top-right
     1.0f, -1.0f,  1.0f, 1.0f,  // bottom-right
};

// NV12 YUV→RGB shader
static const char* kVertexShaderSource = R"(
    attribute vec4 aPosition;
    attribute vec2 aTexCoord;
    varying vec2 vTexCoord;
    uniform vec4 uViewport; // x_offset, y_offset, width, height (normalized)
    void main() {
        // Apply aspect-ratio-correct viewport mapping
        vec2 pos = aPosition.xy * vec2(uViewport.z, uViewport.w) + vec2(uViewport.x, uViewport.y);
        gl_Position = vec4(pos, 0.0, 1.0);
        vTexCoord = aTexCoord;
    }
)";

static const char* kFragmentShaderSource = R"(
    varying highp vec2 vTexCoord;
    uniform sampler2D uTextureY;
    uniform sampler2D uTextureUV;
    void main() {
        highp float y = texture2D(uTextureY, vTexCoord).r;
        highp vec2 uv = texture2D(uTextureUV, vTexCoord).rg;

        // BT.601 YCbCr -> RGB
        highp float r = y + 1.402 * (uv.y - 0.5);
        highp float g = y - 0.344136 * (uv.x - 0.5) - 0.714136 * (uv.y - 0.5);
        highp float b = y + 1.772 * (uv.x - 0.5);

        gl_FragColor = vec4(r, g, b, 1.0);
    }
)";

VideoRenderer::VideoRenderer(QWidget* parent)
    : QOpenGLWidget(parent)
{
}

VideoRenderer::~VideoRenderer() {
    makeCurrent();
    deleteTextures();
    delete m_program;
    if (m_vbo) {
        glDeleteBuffers(1, &m_vbo);
    }
    free(m_yBuffer);
    free(m_uvBuffer);
    doneCurrent();
}

void VideoRenderer::initializeGL() {
    initializeOpenGLFunctions();

    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);

    // Compile shaders
    m_program = new QOpenGLShaderProgram(this);
    m_program->addShaderFromSourceCode(QOpenGLShader::Vertex, kVertexShaderSource);
    m_program->addShaderFromSourceCode(QOpenGLShader::Fragment, kFragmentShaderSource);
    m_program->bindAttributeLocation("aPosition", 0);
    m_program->bindAttributeLocation("aTexCoord", 1);
    m_program->link();

    // Create VBO
    glGenBuffers(1, &m_vbo);
    glBindBuffer(GL_ARRAY_BUFFER, m_vbo);
    glBufferData(GL_ARRAY_BUFFER, sizeof(kVertexData), kVertexData, GL_STATIC_DRAW);
}

void VideoRenderer::resizeGL(int w, int h) {
    glViewport(0, 0, w, h);
}

void VideoRenderer::paintGL() {
    glClear(GL_COLOR_BUFFER_BIT);

    QMutexLocker lock(&m_frameMutex);
    if (!m_hasNewFrame && m_texWidth == 0) return;

    if (m_hasNewFrame && m_frameWidth > 0 && m_frameHeight > 0) {
        // Upload new frame data to textures
        if (m_texWidth != m_frameWidth || m_texHeight != m_frameHeight) {
            createTextures(m_frameWidth, m_frameHeight);
        }

        // Upload Y plane
        glBindTexture(GL_TEXTURE_2D, m_textureY);
        glPixelStorei(GL_UNPACK_ROW_LENGTH, m_yStride);
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, m_frameWidth, m_frameHeight,
                        GL_LUMINANCE, GL_UNSIGNED_BYTE, m_yBuffer);

        // Upload UV plane (half width, half height, 2 components)
        glBindTexture(GL_TEXTURE_2D, m_textureUV);
        glPixelStorei(GL_UNPACK_ROW_LENGTH, m_uvStride / 2);
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, m_frameWidth / 2, m_frameHeight / 2,
                        GL_LUMINANCE_ALPHA, GL_UNSIGNED_BYTE, m_uvBuffer);

        glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
        m_hasNewFrame = false;
    }

    if (m_texWidth == 0) return;

    // Calculate aspect-ratio-correct viewport (letterboxing)
    float widgetAspect = static_cast<float>(width()) / static_cast<float>(height());
    float videoAspect = static_cast<float>(m_texWidth) / static_cast<float>(m_texHeight);

    float scaleX = 1.0f, scaleY = 1.0f;
    float offsetX = 0.0f, offsetY = 0.0f;

    if (videoAspect > widgetAspect) {
        // Video is wider — letterbox top/bottom
        scaleY = widgetAspect / videoAspect;
    } else {
        // Video is taller — pillarbox left/right
        scaleX = videoAspect / widgetAspect;
    }

    lock.unlock();

    m_program->bind();

    // Set viewport uniform
    m_program->setUniformValue("uViewport", offsetX, offsetY, scaleX, scaleY);

    // Bind textures
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, m_textureY);
    m_program->setUniformValue("uTextureY", 0);

    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, m_textureUV);
    m_program->setUniformValue("uTextureUV", 1);

    // Draw
    glBindBuffer(GL_ARRAY_BUFFER, m_vbo);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float), nullptr);
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float),
                          reinterpret_cast<const void*>(2 * sizeof(float)));

    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);

    glDisableVertexAttribArray(0);
    glDisableVertexAttribArray(1);

    m_program->release();
}

void VideoRenderer::onFrameDecoded(AVFrame* frame) {
    if (!frame || frame->width <= 0 || frame->height <= 0) return;

    // FFmpeg NV12: frame->data[0] = Y, frame->data[1] = UV interleaved
    // frame->linesize[0] = Y stride, frame->linesize[1] = UV stride
    // Also handle YUV420P (data[0]=Y, data[1]=U, data[2]=V) — convert to NV12

    QMutexLocker lock(&m_frameMutex);

    int w = frame->width;
    int h = frame->height;

    // Reallocate buffers if size changed
    if (w != m_frameWidth || h != m_frameHeight) {
        free(m_yBuffer);
        free(m_uvBuffer);
        m_yBuffer = static_cast<uint8_t*>(malloc(w * h));
        m_uvBuffer = static_cast<uint8_t*>(malloc(w * h / 2));
        m_frameWidth = w;
        m_frameHeight = h;

        QSize newSize(w, h);
        if (m_videoSize != newSize) {
            m_videoSize = newSize;
            QMetaObject::invokeMethod(this, [this, newSize]() {
                emit videoSizeChanged(newSize);
            }, Qt::QueuedConnection);
        }
    }

    if (frame->format == 23 /* AV_PIX_FMT_NV12 */) {
        // Direct NV12 copy
        m_yStride = frame->linesize[0];
        m_uvStride = frame->linesize[1];
        memcpy(m_yBuffer, frame->data[0], frame->linesize[0] * h);
        memcpy(m_uvBuffer, frame->data[1], frame->linesize[1] * (h / 2));
    } else if (frame->format == 0 /* AV_PIX_FMT_YUV420P */) {
        // Convert YUV420P to NV12
        // Y plane: direct copy
        m_yStride = frame->linesize[0];
        for (int row = 0; row < h; row++) {
            memcpy(m_yBuffer + row * w, frame->data[0] + row * frame->linesize[0], w);
        }
        m_yStride = w;

        // Interleave U and V planes
        int uvH = h / 2;
        int uvW = w / 2;
        for (int row = 0; row < uvH; row++) {
            const uint8_t* uRow = frame->data[1] + row * frame->linesize[1];
            const uint8_t* vRow = frame->data[2] + row * frame->linesize[2];
            uint8_t* dst = m_uvBuffer + row * w;
            for (int col = 0; col < uvW; col++) {
                dst[col * 2]     = uRow[col];
                dst[col * 2 + 1] = vRow[col];
            }
        }
        m_uvStride = w;
    } else {
        qWarning() << "Unsupported pixel format:" << frame->format;
        return;
    }

    m_hasNewFrame = true;
    lock.unlock();

    // Schedule repaint on GUI thread
    QMetaObject::invokeMethod(this, QOverload<>::of(&QWidget::update), Qt::QueuedConnection);
}

void VideoRenderer::createTextures(int width, int height) {
    deleteTextures();

    // Y texture (luminance, full resolution)
    glGenTextures(1, &m_textureY);
    glBindTexture(GL_TEXTURE_2D, m_textureY);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_LUMINANCE, width, height, 0,
                 GL_LUMINANCE, GL_UNSIGNED_BYTE, nullptr);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

    // UV texture (luminance-alpha, half resolution)
    glGenTextures(1, &m_textureUV);
    glBindTexture(GL_TEXTURE_2D, m_textureUV);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_LUMINANCE_ALPHA, width / 2, height / 2, 0,
                 GL_LUMINANCE_ALPHA, GL_UNSIGNED_BYTE, nullptr);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

    m_texWidth = width;
    m_texHeight = height;

    qDebug() << "Created textures:" << width << "x" << height;
}

void VideoRenderer::deleteTextures() {
    if (m_textureY) {
        glDeleteTextures(1, &m_textureY);
        m_textureY = 0;
    }
    if (m_textureUV) {
        glDeleteTextures(1, &m_textureUV);
        m_textureUV = 0;
    }
    m_texWidth = 0;
    m_texHeight = 0;
}
