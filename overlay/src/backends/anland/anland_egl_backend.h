/*
    KWin - the KDE window manager
    This file is part of the KDE project.

    SPDX-License-Identifier: GPL-2.0-or-later

    OpenGL/EGL render backend for the anland backend. It renders the KWin scene
    directly into the dmabuf buffers provided by the display daemon (imported by
    fd) and tells the daemon to present them. Modeled on VirtualEglBackend, with
    the render target being one of the daemon's dmabufs instead of an internal
    FBO. The consumer rotates the buffer index externally (shared memory), so the
    layer keeps per-buffer accumulated damage (buffer-age equivalent), exactly
    like weston's backend-anland.
*/
#pragma once

#include "core/outputlayer.h"
#include "platformsupport/scenes/opengl/abstract_egl_backend.h"

#include <array>
#include <map>
#include <memory>
#include <optional>

extern "C" {
#include "display_producer.h"
#include "protocol.h"
}

namespace KWin
{
class GLFramebuffer;
class GLTexture;
class DrmDevice;
class OutputFrame;
class AnlandBackend;
class AnlandEglBackend;
class AnlandOutput;

class AnlandEglLayer : public OutputLayer
{
public:
    AnlandEglLayer(AnlandOutput *output, AnlandEglBackend *backend);
    ~AnlandEglLayer() override;

    std::optional<OutputLayerBeginFrameInfo> doBeginFrame() override;
    bool doEndFrame(const QRegion &renderedDeviceRegion, const QRegion &damagedDeviceRegion, OutputFrame *frame) override;
    DrmDevice *scanoutDevice() const override;
    QHash<uint32_t, QList<uint64_t>> supportedDrmFormats() const override;
    bool importBuffers(int count);
    void releaseBuffers();

    // True when the most recent completed frame actually repainted something.
    // AnlandOutput uses this to stop handing identical frames to the consumer
    // every vsync, which kept SurfaceFlinger and the GPU busy on a static screen.
    bool lastFrameHadDamage() const
    {
        return m_lastFrameHadDamage;
    }

private:
    void onOutputTransformChanged();

    AnlandEglBackend *const m_backend;
    AnlandOutput *m_output;
    display_ctx *const m_display;

    int m_bufCount = 0;
    int m_currentIndex = 0;
    uint8_t m_damageFlags = 0;
    uint8_t m_damageMask = 0;
    bool m_traceNextFrame = false;
    bool m_lastFrameHadDamage = true;
    quint64 m_frameCount = 0;
    quint64 m_idleFrameCount = 0;
    std::array<std::shared_ptr<GLTexture>, MAX_BUFS> m_textures;
    std::array<std::unique_ptr<GLFramebuffer>, MAX_BUFS> m_fbos;
    std::array<std::optional<RenderTarget>, MAX_BUFS> m_renderTargets;
    std::array<QRegion, MAX_BUFS> m_accumDamage;
};

class AnlandEglBackend : public AbstractEglBackend
{
    Q_OBJECT

public:
    AnlandEglBackend(AnlandBackend *b);
    ~AnlandEglBackend() override;

    void init() override;
    std::unique_ptr<SurfaceTexture> createSurfaceTextureWayland(SurfacePixmap *pixmap) override;
    OutputLayer *primaryLayer(Output *output) override;
    bool present(Output *output, const std::shared_ptr<OutputFrame> &frame) override;
    DrmDevice *drmDevice() const override;

    AnlandBackend *backend() const
    {
        return m_backend;
    }
    display_ctx *display() const;

private:
    bool initializeEgl();
    bool initRenderingContext();

    void addOutput(Output *output);
    void removeOutput(Output *output);

    AnlandBackend *m_backend;
    std::map<Output *, std::unique_ptr<AnlandEglLayer>> m_outputs;
};

} // namespace KWin
