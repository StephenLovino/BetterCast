#pragma once

#include <QOpenGLWidget>
#include <QOpenGLFunctions>
#include <QOpenGLShaderProgram>
#include <QOpenGLTexture>
#include <QMutex>
#include <QSize>

struct AVFrame;

class VideoRenderer : public QOpenGLWidget, protected QOpenGLFunctions {
    Q_OBJECT

public:
    explicit VideoRenderer(QWidget* parent = nullptr);
    ~VideoRenderer();

    QSize videoSize() const { return m_videoSize; }

signals:
    void videoSizeChanged(QSize size);

public slots:
    void onFrameDecoded(AVFrame* frame);

protected:
    void initializeGL() override;
    void paintGL() override;
    void resizeGL(int w, int h) override;

private:
    void uploadFrame(AVFrame* frame);
    void createTextures(int width, int height);
    void deleteTextures();

    QOpenGLShaderProgram* m_program = nullptr;

    // YUV textures (NV12: Y plane + UV interleaved plane)
    GLuint m_textureY = 0;
    GLuint m_textureUV = 0;

    // Vertex buffer
    GLuint m_vbo = 0;

    // Frame dimensions
    QSize m_videoSize;
    int m_texWidth = 0;
    int m_texHeight = 0;

    // Thread-safe frame buffer
    QMutex m_frameMutex;
    uint8_t* m_yBuffer = nullptr;
    uint8_t* m_uvBuffer = nullptr;
    int m_yStride = 0;
    int m_uvStride = 0;
    int m_frameWidth = 0;
    int m_frameHeight = 0;
    bool m_hasNewFrame = false;
};
