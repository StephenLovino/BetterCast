#include "SenderController.h"
#include "VirtualDisplayVDD.h"
#include "VideoEncoderFF.h"
#include "NetworkSender.h"
#include "../LogManager.h"
#include <QDebug>

#ifdef _WIN32
#include "ScreenCaptureWin.h"
#include "InputInjector.h"
#endif
// TODO: #include "ScreenCaptureLinux.h" for PipeWire support

SenderController::SenderController(QObject* parent)
    : QObject(parent)
{
#ifdef _WIN32
    m_vdd = new VirtualDisplayVDD(this);
    connect(m_vdd, &VirtualDisplayVDD::statusChanged,
            this, &SenderController::statusChanged);
    connect(m_vdd, &VirtualDisplayVDD::error,
            this, &SenderController::error);

    // Display setup is deliberately not done here. Advertising a resolution and
    // creating device nodes both need administrator rights, and doing them in
    // the constructor meant a UAC prompt every launch for people who never send
    // a screen. Both happen in startSending() instead, on the first send while
    // nothing is streaming — see prepareDisplays().
#endif
}

SenderController::~SenderController() {
    stopAll();
}

void SenderController::setMonitorIndex(int adapterIndex, int outputIndex) {
    m_adapterIndex = adapterIndex;
    m_outputIndex = outputIndex;
}

SenderController::Session* SenderController::findSession(const QString& host) const {
    for (auto* s : m_sessions) {
        if (s->host == host) return s;
    }
    return nullptr;
}

bool SenderController::isSendingTo(const QString& receiverHost) const {
    return findSession(receiverHost) != nullptr;
}

QStringList SenderController::activeReceivers() const {
    QStringList hosts;
    for (auto* s : m_sessions) hosts << s->host;
    return hosts;
}

QString SenderController::displayForReceiver(const QString& receiverHost) const {
    auto* s = findSession(receiverHost);
    return s ? s->displayName : QString();
}

bool SenderController::isVirtualDisplay(const QString& displayName) const {
    if (displayName.isEmpty() || !m_vdd) return false;
    for (const auto& mon : m_vdd->enumerateMonitors()) {
        if (mon.name.compare(displayName, Qt::CaseInsensitive) == 0) return mon.isVirtual;
    }
    // Unknown to the driver, so it is not one of ours. Treating it as physical
    // is the safe reading: the cost of guessing wrong that way is refusing to
    // resize something, not resizing a monitor someone is working on.
    return false;
}

bool SenderController::displayInUse(const QString& displayName) const {
    if (displayName.isEmpty()) return false;
    for (auto* s : m_sessions) {
        if (s->displayName.compare(displayName, Qt::CaseInsensitive) == 0) return true;
    }
    return false;
}

QVector<QSize> SenderController::setupModes() {
    QVector<QSize> modes = VirtualDisplayVDD::commonResolutions();
    modes.prepend(VirtualDisplayVDD::primaryResolution());
    return modes;
}

bool SenderController::displaySetupPending() const {
#ifdef _WIN32
    if (!m_vdd || m_displaysPrepared || !m_sessions.isEmpty() || !m_vdd->isVddInstalled()) {
        return false;
    }
    return m_vdd->resolutionsMissing(setupModes()) ||
           m_vdd->enumerateVddDevices().size() < qMax(m_desiredPoolSize, kDisplayPoolSize);
#else
    return false;
#endif
}

// Everything that disturbs the display driver, done once, before the first
// stream exists.
//
// Both steps restart the Virtual Display Driver: writing vdd_settings.xml makes
// it reload its mode list, and installing a device node makes it tear down and
// re-enumerate every monitor it owns, which renames each \\.\DISPLAYn and kills
// any capture bound to one. That is survivable with nothing streaming and fatal
// once something is, so it all happens here — on the first send, while the
// session list is still empty. Later sends find the work already done and pass
// straight through.
void SenderController::prepareDisplays() {
    if (!m_vdd || m_displaysPrepared) return;
    m_displaysPrepared = true;

    // Advertise the whole resolution menu, not just the primary's size.
    //
    // Without a size in the driver's mode list, a virtual display comes up at
    // the driver's 800x600 default and no later mode change can lift it —
    // there is nothing better to switch to.
    //
    // A virtual display can only be set to a mode vdd_settings.xml already
    // lists, and updating that file needs elevation and restarts the driver.
    // Writing every offered size once means switching a device's resolution
    // later is a plain mode change — no UAC prompt, no flicker.
    m_vdd->ensureResolutionsAdvertised(setupModes());

    m_vdd->ensureDisplayNodes(qMax(m_desiredPoolSize, kDisplayPoolSize));
}

// Give each receiver a display of its own. Two receivers sharing one display
// would mirror rather than extend, which is the opposite of the point.
QString SenderController::claimDisplayFor(const QString& host, const QSize& target) {
    Q_UNUSED(host);
    if (!m_vdd) return QString();

    // A VDD device node can exist while its monitor is detached from the
    // desktop; it then reports 0x0 and has no framebuffer at all. Handing one
    // of those to capture is what made every receiver after the first show the
    // primary panel — capture failed and fell through to the whole desktop.
    // Only ever claim a display that is actually attached.
    auto attachedAndFree = [this](const VirtualDisplayVDD::MonitorInfo& m) {
        return m.isVirtual && m.attached && !displayInUse(m.name);
    };

    // One already at the wanted size first: streaming it needs no mode change,
    // and every mode change blanks every screen on the machine.
    const auto monitors = m_vdd->enumerateMonitors();
    for (const auto& mon : monitors) {
        if (attachedAndFree(mon) && mon.width == target.width() &&
            mon.height == target.height()) {
            return mon.name;
        }
    }
    for (const auto& mon : monitors) {
        if (attachedAndFree(mon)) return mon.name;
    }

    // Nothing attached and free. Prefer waking a detached node we already have
    // over adding another one — the machine accumulates monitors otherwise.
    for (const auto& mon : m_vdd->enumerateMonitors()) {
        if (!mon.isVirtual || displayInUse(mon.name)) continue;
        if (mon.attached) continue;   // already handled above

        LogManager::instance().log(
            "Sender: " + mon.name + " exists but is detached — attaching it");
        if (m_vdd->attachVirtualDisplay(mon.name, target.width(), target.height())) {
            for (const auto& refreshed : m_vdd->enumerateMonitors()) {
                if (refreshed.name.compare(mon.name, Qt::CaseInsensitive) == 0 &&
                    refreshed.attached) {
                    return refreshed.name;
                }
            }
        }
    }

    // Out of nodes. Adding one here is what broke the third receiver: installing
    // a VDD device node makes the driver tear down and re-enumerate every
    // monitor it owns, so the \\.\DISPLAYn name each live session was capturing
    // stops existing ("Failed to reinitialize desktop duplication") and the new
    // monitor is not ready for several seconds either, so the attach that
    // follows returns DISP_CHANGE_FAILED. The pool is built up front in
    // startSending() instead, while nothing is streaming. Never grow it under a
    // live stream.
    if (!m_sessions.isEmpty()) {
        LogManager::instance().log(
            "Sender: Every virtual display is in use and more cannot be added while "
            "streaming — adding one restarts the driver and would interrupt the "
            "streams already running.");
        // Remember that a bigger pool is wanted, and let it be built the next
        // time the session list is empty.
        m_desiredPoolSize = m_sessions.size() + 1;
        m_displaysPrepared = false;
        return QString();
    }

    if (m_autoAddFailed) {
        LogManager::instance().log(
            "Sender: Not retrying the automatic display add — it already failed once "
            "this session. Use \"Create Virtual Display\".");
        return QString();
    }

    LogManager::instance().log(
        "Sender: No attached virtual display is free — adding one for this receiver");
    if (m_vdd->addVddDeviceNode()) {
        for (const auto& mon : m_vdd->enumerateMonitors()) {
            if (attachedAndFree(mon)) return mon.name;
        }
        // Created but not attached yet — wake it the same way as any other.
        for (const auto& mon : m_vdd->enumerateMonitors()) {
            if (!mon.isVirtual || mon.attached || displayInUse(mon.name)) continue;
            if (m_vdd->attachVirtualDisplay(mon.name, target.width(), target.height())) {
                for (const auto& refreshed : m_vdd->enumerateMonitors()) {
                    if (refreshed.name.compare(mon.name, Qt::CaseInsensitive) == 0 &&
                        refreshed.attached) {
                        return refreshed.name;
                    }
                }
            }
        }
    }
    m_autoAddFailed = true;
    return QString();
}

bool SenderController::startSending(const QString& receiverHost, uint16_t port,
                                    int fps, int bitrateMbps,
                                    const QString& displayName,
                                    int width, int height) {
    if (receiverHost.isEmpty()) {
        emit error("No receiver address given");
        return false;
    }
    if (findSession(receiverHost)) {
        LogManager::instance().log("Sender: Already streaming to " + receiverHost);
        return false;
    }

#ifndef _WIN32
    emit error("Screen capture not yet supported on this platform");
    emit statusChanged("Sender not available on this platform yet");
    return false;
#else
    if (m_sessions.isEmpty()) prepareDisplays();

    // A mirrored virtual display shares the primary's framebuffer, so capturing
    // it would just stream a copy of the primary. Fix the topology first.
    if (m_vdd) {
        auto topo = m_vdd->queryTopology();
        if (topo.valid && topo.anyCloned) {
            emit statusChanged("Display is mirrored — switching to extend...");
            m_vdd->ensureExtendedTopology();
        }
    }

    auto* s = new Session();
    s->host = receiverHost;
    s->port = port;
    s->fps = fps;
    s->bitrateMbps = bitrateMbps;
    s->width = width;
    s->height = height;

    // Explicit display wins; then the UI default if free; then claim a spare.
    s->displayName = displayName;
    if (s->displayName.isEmpty() && !displayInUse(m_displayName)) {
        s->displayName = m_displayName;
        s->adapterIndex = m_adapterIndex;
        s->outputIndex = m_outputIndex;
    }

    // Naming a monitor the user is looking at is a mirror request, matching the
    // macOS sender's "Mirror Built-in". Two things below would quietly turn
    // that back into an extend: claiming a spare virtual display when this one
    // looks busy, and raising the resolution of whatever was chosen. Neither
    // may happen to a real monitor — the second would change the resolution of
    // a screen someone is working on.
    const bool mirroring = !s->displayName.isEmpty() && !isVirtualDisplay(s->displayName);
    if (mirroring && displayInUse(s->displayName)) {
        emit error(QString("%1 is already being mirrored to another receiver. Windows can "
                           "only duplicate a display once, so mirror to one device at a "
                           "time — or extend, which gives each receiver its own screen.")
                       .arg(s->displayName));
        delete s;
        return false;
    }

    // Decided before a display is claimed, so a detached one can be attached at
    // this size in one display change. Per-device size when one was chosen,
    // otherwise match the primary.
    const QSize target = (s->width > 0 && s->height > 0)
        ? QSize(s->width, s->height)
        : VirtualDisplayVDD::primaryResolution();

    if (!mirroring && (s->displayName.isEmpty() || displayInUse(s->displayName))) {
        const QString claimed = claimDisplayFor(receiverHost, target);
        if (claimed.isEmpty()) {
            emit error(m_sessions.isEmpty()
                ? QString("No display available for %1. Press \"Create Virtual "
                          "Display\".").arg(receiverHost)
                : QString("No spare virtual display for %1. Stop every stream and "
                          "start again — BetterCast can only add displays when "
                          "nothing is streaming, because adding one restarts the "
                          "display driver.").arg(receiverHost));
            delete s;
            return false;
        }
        s->displayName = claimed;
    } else if (m_vdd) {
        // An explicitly chosen display may still be a detached VDD monitor
        // (0x0 in the picker). Attach it rather than capturing nothing.
        for (const auto& mon : m_vdd->enumerateMonitors()) {
            if (mon.name.compare(s->displayName, Qt::CaseInsensitive) != 0) continue;
            if (mon.isVirtual && !mon.attached) {
                emit statusChanged("Attaching " + s->displayName + "...");
                if (!m_vdd->attachVirtualDisplay(s->displayName, target.width(),
                                                 target.height())) {
                    emit error(s->displayName + " could not be attached to the desktop, "
                                                "so there is nothing to capture.");
                    delete s;
                    return false;
                }
            }
            break;
        }
    }

    // Windows brings an extended virtual display up at the driver's 800x600
    // default. Raise it before capture starts, or the stream goes out at 800x600.
    // A no-op when the display was attached at `target` above.
    if (m_vdd && !mirroring) {
        m_vdd->setVirtualDisplayResolution(s->displayName, target.width(), target.height());
    }

    LogManager::instance().log(
        QString("Sender: Streaming %1 to %2 (session %3 of %4)")
            .arg(s->displayName, receiverHost)
            .arg(m_sessions.size() + 1).arg(m_sessions.size() + 1));

    auto* cap = new ScreenCaptureWin(fps, this);
    cap->setMonitorIndex(s->adapterIndex, s->outputIndex);
    cap->setDisplayName(s->displayName);
    s->capture = cap;

    s->encoder = new VideoEncoderFF(this);
    s->network = new NetworkSender(this);

    // Input travels back over the same socket. Point the injector at this
    // session's display so events land there, not on the primary.
    s->input = new InputInjector(this);
    s->input->setTargetDisplayName(s->displayName);

    // Capture → encode is DIRECT so both run on this session's capture thread.
    // A queued connection would hop back to the GUI thread and serialise every
    // session behind Qt painting, which defeats the point of separate pipelines.
    connect(s->capture, &ScreenCapture::frameCaptured, this,
            [this, s](const QByteArray& nv12, int w, int h, qint64 pts) {
                onFrameCaptured(s, nv12, w, h, pts);
            }, Qt::DirectConnection);
    connect(s->capture, &ScreenCapture::error, this, &SenderController::error);

    // Encode → network is QUEUED: QTcpSocket is thread-affine to the GUI thread.
    connect(s->encoder, &VideoEncoderFF::encoded, this,
            [this, s](const QByteArray& payload) { onEncoded(s, payload); },
            Qt::QueuedConnection);
    connect(s->encoder, &VideoEncoderFF::error, this, &SenderController::error);

    connect(s->network, &NetworkSender::connected, this, [this, s]() { onSessionConnected(s); });
    connect(s->network, &NetworkSender::disconnected, this, [this, s]() { onSessionDisconnected(s); });
    connect(s->network, &NetworkSender::error, this, &SenderController::error);
    connect(s->network, &NetworkSender::inputPacket, s->input, &InputInjector::handlePacket);

    connect(s->input, &InputInjector::keyframeRequested, this, [s]() {
        // Receivers ask after a decode error, so a run of these lines next to
        // a flicker report points at corruption rather than display changes.
        LogManager::instance().log("Sender: " + s->host + " requested a keyframe");
        if (s->encoder) s->encoder->requestKeyframe();
    });
    connect(s->input, &InputInjector::injectionBlocked, this, [this](const QString& msg) {
        emit statusChanged("Input blocked: " + msg);
    });

    m_sessions.append(s);

    emit statusChanged(QString("Connecting to %1...").arg(receiverHost));
    s->network->connectTo(receiverHost, port);

    emit started(receiverHost);
    emit sessionsChanged();
    return true;
#endif
}

void SenderController::destroySession(Session* s) {
    if (!s) return;

    // Order matters: capture->stop() joins the capture thread, so it must
    // complete before the encoder it calls into is deleted.
    if (s->capture) {
        s->capture->stop();
        delete s->capture;
        s->capture = nullptr;
    }
    if (s->encoder) {
        s->encoder->shutdown();
        delete s->encoder;
        s->encoder = nullptr;
    }
    if (s->network) {
        s->network->disconnect();
        delete s->network;
        s->network = nullptr;
    }
    if (s->input) {
        delete s->input;
        s->input = nullptr;
    }
    delete s;
}

void SenderController::stopSending(const QString& receiverHost) {
    auto* s = findSession(receiverHost);
    if (!s) return;

    m_sessions.removeAll(s);
    const QString host = s->host;
    destroySession(s);

    LogManager::instance().log("Sender: Stopped streaming to " + host);
    emit stopped(host);
    emit sessionsChanged();
    emit statusChanged(m_sessions.isEmpty()
                           ? QString("Sender stopped")
                           : QString("Streaming to %1 receiver(s)").arg(m_sessions.size()));
}

void SenderController::stopAll() {
    const auto sessions = m_sessions;
    m_sessions.clear();
    for (auto* s : sessions) {
        const QString host = s->host;
        destroySession(s);
        emit stopped(host);
    }
    if (!sessions.isEmpty()) {
        emit sessionsChanged();
        emit statusChanged("Sender stopped");
    }
}

void SenderController::onSessionConnected(Session* s) {
    if (!s) return;
    qDebug() << "Sender: Connected to" << s->host << "— starting capture";
    emit connected(s->host);
    emit statusChanged(QString("Connected to %1 — starting capture...").arg(s->host));

    if (s->capture && !s->capture->isRunning()) {
        if (!s->capture->start()) {
            emit error(QString("Failed to start screen capture for %1").arg(s->host));
            const QString host = s->host;
            QMetaObject::invokeMethod(this, [this, host]() { stopSending(host); },
                                      Qt::QueuedConnection);
        }
    }
}

void SenderController::onSessionDisconnected(Session* s) {
    if (!s) return;
    const QString host = s->host;
    qDebug() << "Sender: Disconnected from" << host;
    emit disconnected(host);
    // Tear down on the GUI thread — this can arrive from socket callbacks.
    QMetaObject::invokeMethod(this, [this, host]() { stopSending(host); },
                              Qt::QueuedConnection);
}

void SenderController::onFrameCaptured(Session* s, const QByteArray& nv12,
                                       int width, int height, qint64 ptsNanos) {
    if (!s || !s->encoder) return;

    // Lazy-init the encoder on the first frame, which is when the real
    // resolution of this session's display is known.
    if (!s->encoderReady) {
        if (!s->encoder->init(width, height, s->fps, s->bitrateMbps)) {
            emit error(QString("Failed to initialize H.264 encoder for %1").arg(s->host));
            // Do NOT tear down inline — we are on this session's capture thread
            // and stopSending() joins it, which would deadlock.
            const QString host = s->host;
            QMetaObject::invokeMethod(this, [this, host]() { stopSending(host); },
                                      Qt::QueuedConnection);
            return;
        }
        s->encoderReady = true;
        const QString streaming = QString("Streaming %1x%2 to %3 via %4")
                                      .arg(width).arg(height).arg(s->host, s->encoder->encoderName());
        // Which encoder was picked decides most of the image-quality behaviour,
        // and until now it only reached the status bar.
        LogManager::instance().log("Sender: " + streaming);
        emit statusChanged(streaming);
        s->encoder->requestKeyframe();
    }

    s->encoder->encode(nv12, width, height, ptsNanos);
}

void SenderController::onEncoded(Session* s, const QByteArray& payload) {
    if (s && s->network && s->network->isConnected()) {
        s->network->sendVideo(payload);
    }
}

QString SenderController::encoderInfo() const {
    for (auto* s : m_sessions) {
        if (s->encoder && s->encoder->isInitialized()) return s->encoder->encoderName();
    }
    return "Not initialized";
}
