#include "SenderController.h"
#include "VirtualDisplayVDD.h"
#include "VideoEncoderFF.h"
#include "NetworkSender.h"
#include "../LogManager.h"
#include <QDebug>
#include <QSettings>
#include <QUrl>

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

bool SenderController::displaySetupPending(const QString& receiverName) const {
#ifdef _WIN32
    if (!m_vdd || !m_vdd->isVddInstalled()) return false;

    // Advertising modes restarts the driver. Only checked on a first send.
    if (m_sessions.isEmpty() && !m_displaysPrepared &&
        m_vdd->resolutionsMissing(setupModes())) {
        return true;
    }

    // A node install re-enumerates every virtual display. It is needed only
    // when no present node is free - this receiver's own, or anyone's.
    Q_UNUSED(receiverName);
    for (const auto& d : m_vdd->enumerateVddDevices()) {
        if (d.isVddDriver && !nodeInUse(d.instanceId)) return false;
    }
    return true;
#else
    Q_UNUSED(receiverName);
    return false;
#endif
}

// ─── Receiver ↔ virtual display assignments ─────────────────────────────────
//
// QSettings "BetterCast/BetterCast", the same store the glass bridge keeps
// per-device stream settings in, so both builds agree on who owns what:
//   virtualDisplays/<percent-encoded node id> = receiver name
// Keyed by node, never by \\.\DISPLAYn, because those are reissued every time
// the driver re-enumerates.

static QString assignmentKey(const QString& instanceId) {
    return QStringLiteral("virtualDisplays/") +
           QString::fromLatin1(QUrl::toPercentEncoding(instanceId.toUpper()));
}

void SenderController::assignDisplay(const QString& receiverName, const QString& instanceId) {
    if (receiverName.isEmpty() || instanceId.isEmpty()) return;
    QSettings settings("BetterCast", "BetterCast");
    // One display per receiver, and one receiver per display.
    settings.beginGroup("virtualDisplays");
    for (const QString& key : settings.childKeys()) {
        if (settings.value(key).toString() == receiverName) settings.remove(key);
    }
    settings.endGroup();
    if (settings.value(assignmentKey(instanceId)).toString() != receiverName) {
        LogManager::instance().log(QString("Sender: %1 is now %2's virtual display")
                                       .arg(instanceId.toUpper(), receiverName));
    }
    settings.setValue(assignmentKey(instanceId), receiverName);
}

QString SenderController::receiverForNode(const QString& instanceId) const {
    if (instanceId.isEmpty()) return QString();
    return QSettings("BetterCast", "BetterCast").value(assignmentKey(instanceId)).toString();
}

QString SenderController::receiverForDisplay(const QString& displayName) const {
    return m_vdd ? receiverForNode(m_vdd->nodeForDisplay(displayName)) : QString();
}

QString SenderController::virtualDisplayFor(const QString& receiverName) const {
    if (receiverName.isEmpty()) return QString();
    QSettings settings("BetterCast", "BetterCast");
    settings.beginGroup("virtualDisplays");
    for (const QString& key : settings.childKeys()) {
        if (settings.value(key).toString() == receiverName) {
            return QUrl::fromPercentEncoding(key.toLatin1()).toUpper();
        }
    }
    return QString();
}

void SenderController::clearDisplayAssignments() {
    QSettings("BetterCast", "BetterCast").remove("virtualDisplays");
}

bool SenderController::nodeInUse(const QString& instanceId) const {
    if (instanceId.isEmpty()) return false;
    for (auto* s : m_sessions) {
        if (s->nodeId.compare(instanceId, Qt::CaseInsensitive) == 0) return true;
    }
    return false;
}

bool SenderController::streamingToVirtualDisplay() const {
    for (auto* s : m_sessions) {
        if (!s->nodeId.isEmpty()) return true;
    }
    return false;
}

QVector<SenderController::VirtualDisplayEntry> SenderController::virtualDisplays() const {
    QVector<VirtualDisplayEntry> out;
#ifdef _WIN32
    if (!m_vdd) return out;
    for (const auto& d : m_vdd->enumerateVddDevices(true)) {
        if (!d.isVddDriver) continue;
        VirtualDisplayEntry e;
        e.instanceId = d.instanceId.toUpper();
        e.present = d.present;
        e.receiverName = receiverForNode(e.instanceId);
        e.displayName = d.present ? m_vdd->displayForNode(e.instanceId) : QString();
        e.inUse = nodeInUse(e.instanceId);
        out.append(e);
    }
#endif
    return out;
}

bool SenderController::removeVirtualDisplay(const QString& instanceId) {
#ifdef _WIN32
    if (!m_vdd || instanceId.isEmpty()) return false;
    if (streamingToVirtualDisplay()) {
        emit error("Stop streaming before removing a virtual display. Removing one makes "
                   "the display driver restart all of its displays, which interrupts "
                   "the streams running on them.");
        return false;
    }
    const bool ok = m_vdd->removeVddDevice(instanceId);
    if (ok) QSettings("BetterCast", "BetterCast").remove(assignmentKey(instanceId));
    return ok;
#else
    Q_UNUSED(instanceId);
    return false;
#endif
}

#ifdef _WIN32
// A node install makes the driver tear down and re-enumerate every monitor it
// owns. Each \\.\DISPLAYn is reissued, so a capture bound to one dies: DXGI
// reports ACCESS_LOST and the reinit that follows either fails or duplicates
// whatever output now sits at the old index. A session's node does not change,
// so look its display up again by node and restart the capture there. The
// receiver sees a pause of a few seconds instead of a dead stream.
void SenderController::rebindSessionsAfterReenumeration() {
    if (!m_vdd) return;
    for (auto* s : m_sessions) {
        if (s->nodeId.isEmpty() || !s->capture) continue;

        const QString host = s->host;
        const QString name = m_vdd->displayForNode(s->nodeId);
        if (name.isEmpty()) {
            LogManager::instance().log(
                QString("Sender: %1's display (%2) did not come back after the driver "
                        "re-enumerated — stopping that stream").arg(host, s->nodeId));
            QMetaObject::invokeMethod(this, [this, host]() { stopSending(host); },
                                      Qt::QueuedConnection);
            continue;
        }

        const QSize size = (s->width > 0 && s->height > 0)
            ? QSize(s->width, s->height) : VirtualDisplayVDD::primaryResolution();
        bool attached = false;
        for (const auto& mon : m_vdd->enumerateMonitors()) {
            if (mon.name.compare(name, Qt::CaseInsensitive) == 0) attached = mon.attached;
        }
        if (!attached && !m_vdd->attachVirtualDisplay(name, size.width(), size.height())) {
            LogManager::instance().log(
                QString("Sender: could not re-attach %1 for %2 — stopping that stream")
                    .arg(name, host));
            QMetaObject::invokeMethod(this, [this, host]() { stopSending(host); },
                                      Qt::QueuedConnection);
            continue;
        }
        m_vdd->setVirtualDisplayResolution(name, size.width(), size.height());

        LogManager::instance().log(
            QString("Sender: %1 moved from %2 to %3 when the driver re-enumerated — "
                    "restarting its capture").arg(host, s->displayName, name));
        s->capture->stop();   // joins the dead capture thread
        s->displayName = name;
        if (auto* cap = qobject_cast<ScreenCaptureWin*>(s->capture)) cap->setDisplayName(name);
        if (s->input) s->input->setTargetDisplayName(name);
        if (s->network && s->network->isConnected() && !s->capture->start()) {
            emit error(QString("Could not restart the capture for %1").arg(host));
            QMetaObject::invokeMethod(this, [this, host]() { stopSending(host); },
                                      Qt::QueuedConnection);
            continue;
        }
        // The encoder restarts itself if the size changed; a keyframe gets the
        // receiver's picture back straight away either way.
        if (s->encoder) s->encoder->requestKeyframe();
    }
}
#endif

// The one-time driver setup: make sure every size a virtual display may run at
// is in vdd_settings.xml. Writing it restarts the Virtual Display Driver, which
// is survivable with nothing streaming, so it happens on the first send while
// the session list is still empty. Displays themselves are no longer created
// here - see claimDisplayFor().
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
}

// Give each receiver a display of its own. Two receivers sharing one display
// would mirror rather than extend, which is the opposite of the point.
QString SenderController::claimDisplayFor(const QString& host, const QString& receiverName,
                                          const QSize& target) {
    Q_UNUSED(host);
    if (!m_vdd) return QString();

    // Attach a detached display at the stream's size and confirm it took.
    // A VDD node can exist while its monitor is detached, reporting 0x0 with no
    // framebuffer; handing one of those to capture is what once made receivers
    // show the primary panel. Only ever return a display that is attached.
    auto attachAt = [this, &target](const QString& name) -> QString {
        LogManager::instance().log("Sender: " + name + " exists but is detached — attaching it");
        if (!m_vdd->attachVirtualDisplay(name, target.width(), target.height())) return QString();
        for (const auto& refreshed : m_vdd->enumerateMonitors()) {
            if (refreshed.name.compare(name, Qt::CaseInsensitive) == 0 && refreshed.attached) {
                return refreshed.name;
            }
        }
        return QString();
    };

    // 1. This receiver's own display, so a device comes back to the same one.
    const QString ownNode = virtualDisplayFor(receiverName);
    if (!ownNode.isEmpty() && !nodeInUse(ownNode)) {
        const QString name = m_vdd->displayForNode(ownNode);
        if (!name.isEmpty()) {
            for (const auto& mon : m_vdd->enumerateMonitors()) {
                if (mon.name.compare(name, Qt::CaseInsensitive) != 0) continue;
                if (mon.attached) return mon.name;
                const QString attached = attachAt(mon.name);
                if (!attached.isEmpty()) return attached;
                break;
            }
        }
    }

    // 2. A free existing display. Unassigned ones before another receiver's,
    // and within that, one already at the wanted size - streaming it needs no
    // mode change, and every mode change blanks every screen on the machine.
    // Reusing another receiver's display beats adding a node: that costs a UAC
    // prompt and re-enumerates every virtual display.
    const auto monitors = m_vdd->enumerateMonitors();
    auto isFree = [this](const VirtualDisplayVDD::MonitorInfo& m) {
        return m.isVirtual && !displayInUse(m.name) && !nodeInUse(m_vdd->nodeForDisplay(m.name));
    };
    auto unassigned = [this](const VirtualDisplayVDD::MonitorInfo& m) {
        return receiverForDisplay(m.name).isEmpty();
    };
    for (int pass = 0; pass < 2; pass++) {
        const bool wantUnassigned = (pass == 0);
        for (const auto& mon : monitors) {
            if (isFree(mon) && mon.attached && unassigned(mon) == wantUnassigned &&
                mon.width == target.width() && mon.height == target.height()) {
                return mon.name;
            }
        }
        for (const auto& mon : monitors) {
            if (isFree(mon) && mon.attached && unassigned(mon) == wantUnassigned) return mon.name;
        }
        for (const auto& mon : monitors) {
            if (!isFree(mon) || mon.attached || unassigned(mon) != wantUnassigned) continue;
            const QString attached = attachAt(mon.name);
            if (!attached.isEmpty()) return attached;
        }
    }

    // 3. None free: add one for this receiver.
    if (m_autoAddFailed) {
        LogManager::instance().log(
            "Sender: Not retrying the automatic display add — it already failed once "
            "this session. Use \"Create Virtual Display\".");
        return QString();
    }

    const bool othersLive = streamingToVirtualDisplay();
    LogManager::instance().log(othersLive
        ? QString("Sender: No virtual display is free — adding one for %1. Streams on "
                  "other virtual displays pause while the driver re-enumerates, then "
                  "resume on their renumbered displays.").arg(receiverName.isEmpty() ? host : receiverName)
        : QString("Sender: No virtual display is free — adding one for %1")
              .arg(receiverName.isEmpty() ? host : receiverName));

    if (m_vdd->addVddDeviceNode()) {
        // Every \\.\DISPLAYn the driver owns has just been reissued.
        rebindSessionsAfterReenumeration();

        const auto fresh = m_vdd->enumerateMonitors();
        for (const auto& mon : fresh) {
            if (isFree(mon) && mon.attached && unassigned(mon)) return mon.name;
        }
        for (const auto& mon : fresh) {
            if (!isFree(mon) || mon.attached) continue;
            const QString attached = attachAt(mon.name);
            if (!attached.isEmpty()) return attached;
        }
    }
    m_autoAddFailed = true;
    return QString();
}

bool SenderController::startSending(const QString& receiverHost, uint16_t port,
                                    int fps, int bitrateMbps,
                                    const QString& displayName,
                                    int width, int height,
                                    const QString& receiverName) {
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
    s->receiverName = receiverName;
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
        const QString claimed = claimDisplayFor(receiverHost, receiverName, target);
        if (claimed.isEmpty()) {
            emit error(QString("No virtual display could be set up for %1 — the log "
                               "says why. \"Create Virtual Display\" adds one by hand.")
                           .arg(receiverName.isEmpty() ? receiverHost : receiverName));
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

        // Remember the node rather than the name: the name is reissued if the
        // driver re-enumerates, and the node is how this session is found again.
        s->nodeId = m_vdd->nodeForDisplay(s->displayName);
        assignDisplay(receiverName, s->nodeId);
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
