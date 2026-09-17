#include "BetterCastBridge.h"

#include "AdbHelper.h"
#include "AdbInputInjector.h"
#include "AudioDecoder.h"
#include "AudioPlayer.h"
#include "HotspotManager.h"
#include "InputHandler.h"
#include "VideoWindow.h"
#include "LogManager.h"
#include "NetworkListener.h"
#include "ServiceDiscovery.h"
#include "VideoDecoder.h"
#include "VideoRenderer.h"
#include "Language.h"
#include "UpdateChecker.h"
#include "DonatePrompt.h"
#include "QrImage.h"   // WIFI: payload and the qrcodegen encoder, shared with the Qt app
#ifdef ENABLE_SENDER
#include "sender/SenderController.h"
#include "sender/VirtualDisplayVDD.h"
#endif

#include <QApplication>
#include <QDesktopServices>
#include <QFileInfo>
#include <QHostAddress>
#include <QNetworkInterface>
#include <QSettings>
#include <QSurfaceFormat>
#include <QSysInfo>
#include <QUrl>
#include <QCoreApplication>
#include <QOpenGLWidget>
#include <QDataStream>
#include <QJsonDocument>
#include <QJsonObject>
#include <QProcess>
#include <QRegularExpression>
#include <QStandardPaths>
#include <QTcpSocket>

#include <map>
#include <QTimer>

#include <chrono>
#include <memory>
#include <mutex>
#include <thread>

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <Windows.h>
#endif

namespace BetterCastBridge {

// Matches IDI_APPICON in the resource script the build generates. Windows
// shows the lowest-numbered icon resource as the file's icon in Explorer, so
// this being the only one is deliberate.
constexpr int kAppIconResourceId = 101;

// How many log lines to keep. The console window that used to carry these is
// gone - the app is a windowed binary now - so this is the only place they
// live at runtime, and it wants to be long enough to cover starting a stream
// and watching it fail.
constexpr size_t kLogScrollback = 1000;

// Declared up here rather than below the helpers, because the helpers call
// them: anything inside the anonymous namespace that asks for a frame needs
// requestRedraw to already be a name.
void requestRedraw();   // defined below, used by init's connections
int  sessionCount();    // defined below, used by the render throttle

namespace {

std::unique_ptr<QApplication>     g_app;
std::unique_ptr<ServiceDiscovery> g_discovery;
std::unique_ptr<QOpenGLWidget>    g_probe;
std::unique_ptr<NetworkListener>  g_network;
std::unique_ptr<VideoDecoder>     g_decoder;
std::unique_ptr<VideoRenderer>    g_renderer;   // owned by g_videoWindow once built
std::unique_ptr<VideoWindow>      g_videoWindow;
std::unique_ptr<InputHandler>     g_input;
std::unique_ptr<AudioDecoder>     g_audioDecoder;
std::unique_ptr<AudioPlayer>      g_audioPlayer;
std::unique_ptr<HotspotManager>   g_hotspot;
std::unique_ptr<AdbHelper>        g_adbHelper;
QTimer*                           g_hotspotTimer = nullptr;
bool                              g_hotspotWanted = false;
std::string                       g_cableStatus;
bool                              g_cableBusy = false;

// A cable (adb) stream is running or being brought back. While it is, clicks in
// the receive window also go to the phone through adb, and a dropped stream is
// redialled - the way the macOS receiver does both.
bool                              g_cableSession = false;
bool                              g_cableDialling = false;  // a connectTo() in flight
bool                              g_wirelessAdbTried = false;
int                               g_cableReconnects = 0;
QTimer*                           g_cableReconnectTimer = nullptr;
std::unique_ptr<AdbInputInjector> g_adbInput;
QSize                             g_streamSize;
// AdbHelper is not thread-safe and three worker threads can use it: connect,
// reconnect and the wireless-adb switch.
std::mutex                        g_adbMutex;
constexpr int                     kCableReconnectMax = 15;
constexpr int                     kCableReconnectMs = 3000;
std::string                       g_androidWifiStatus;
std::string                       g_androidWifiHost;   // the address being dialled, if any
// Something is sending us a screen right now. The event pump has to keep up
// with it, which it will not do on the idle cadence.
bool                              g_receiving = false;
std::unique_ptr<UpdateChecker>    g_updates;
std::string g_updateStatus;
std::string g_updateUrl;
#ifdef ENABLE_SENDER
std::unique_ptr<SenderController> g_sender;
#endif

std::vector<Device>      g_devices;
std::string              g_lastLog;
std::vector<std::string> g_logLines;
int                      g_frameCap = 60;

#ifdef _WIN32
POINT    g_lastCursor    = {};
bool     g_wasForeground = false;
uint64_t g_lastActivity  = 0;
uint64_t g_lastDraw      = 0;
uint64_t g_redrawUntil   = 0;

uint64_t nowMs() {
    return static_cast<uint64_t>(GetTickCount64());
}
#else
uint64_t g_redrawUntil = 0;
uint64_t nowMs() { return 0; }
#endif

// argv has to outlive QApplication: it keeps the pointer, and Qt reads it
// again during shutdown. A local array in init() would be long gone by then.
int    g_argc = 0;
char** g_argv = nullptr;

void refreshDevices() {
    g_devices.clear();
    if (!g_discovery) return;

    const auto& found = g_discovery->discoveredServices();

    // Names Apple advertises twice: a Wi-Fi service and an AWDL "<name> P2P"
    // one. macOS hides the P2P copy when the base device is present; without
    // that both appear and the P2P one is the broken half.
    auto hasBase = [&found](const QString& p2pName) {
        const QString base = p2pName.left(p2pName.length() - 4);   // strip " P2P"
        for (const auto& o : found) {
            if (o.name == base) return true;
        }
        return false;
    };

    for (const auto& s : found) {
        if (s.name.endsWith(" P2P") && hasBase(s.name)) continue;

        // An AWDL target is a .local hostname on a link Windows has no route
        // to, so it never resolves - "Host not found" is the whole story of
        // the iPhone failing to connect. Skip anything that is not an address
        // we can actually dial.
        const QHostAddress addr(s.host);
        if (addr.isNull()) continue;

        Device d;
        d.name = s.name.toStdString();
        d.host = s.host.toStdString();
        // Every BetterCast receiver listens on 51820. mDNS may advertise the
        // P2P listener's dynamic port instead, which is unreachable from here.
        // MainWindow has forced this for the Qt app all along; the bridge was
        // reading the raw SRV record and dialling 57510.
        d.port = 51820;
        g_devices.push_back(std::move(d));
    }
}

// The display device name of the screen the user is looking at, e.g.
// "\\.\DISPLAY1", for mirroring.
//
// Asked of Windows rather than inferred from the monitor list: the primary is
// whichever adapter carries the PRIMARY_DEVICE flag, which is not reliably the
// first one, and picking the wrong screen would mirror the wrong desktop.
QString mainDisplayName() {
#ifdef _WIN32
    DISPLAY_DEVICEW dd = {};
    dd.cb = sizeof(dd);
    for (DWORD i = 0; EnumDisplayDevicesW(nullptr, i, &dd, 0); i++) {
        const bool attached = (dd.StateFlags & DISPLAY_DEVICE_ATTACHED_TO_DESKTOP) != 0;
        const bool primary  = (dd.StateFlags & DISPLAY_DEVICE_PRIMARY_DEVICE) != 0;
        if (attached && primary) return QString::fromWCharArray(dd.DeviceName);
        dd.cb = sizeof(dd);
    }
#endif
    return QString();
}

// ── Android over USB ─────────────────────────────────────────────────────

std::vector<AndroidDevice> g_androids;
std::string                g_androidStatus;
bool                       g_androidWatching = false;
QProcess*                  g_adb       = nullptr;   // one probe at a time
QTimer*                    g_adbTimer  = nullptr;

// scrcpy and adb, bundled in a folder beside the exe. Falls back to PATH, so
// a machine that already has the Android tools installed works too.
QString androidTool(const QString& exe) {
    const QString bundled =
        QCoreApplication::applicationDirPath() + "/scrcpy/" + exe;
    if (QFileInfo::exists(bundled)) return bundled;

    QString base = exe;
    if (base.endsWith(".exe", Qt::CaseInsensitive)) base.chop(4);
    return QStandardPaths::findExecutable(base);
}

void parseAdbDevices(const QString& out) {
    std::vector<AndroidDevice> found;
    const QStringList lines = out.split(QChar('\n'), Qt::SkipEmptyParts);
    for (const QString& raw : lines) {
        const QString line = raw.trimmed();
        // The header, and the noise adb prints while starting its daemon.
        if (line.isEmpty()) continue;
        if (line.startsWith("List of devices")) continue;
        if (line.startsWith('*')) continue;

        const QStringList parts = line.split(QRegularExpression("\\s+"),
                                             Qt::SkipEmptyParts);
        if (parts.size() < 2) continue;

        AndroidDevice d;
        d.serial = parts[0].toStdString();
        d.state  = parts[1].toStdString();
        // "model:Pixel_7" when adb was asked for the long listing. Underscores
        // are adb's, not the owner's, so they read better as spaces.
        for (int i = 2; i < parts.size(); i++) {
            if (!parts[i].startsWith("model:")) continue;
            QString m = parts[i].mid(6);
            m.replace(QChar('_'), QChar(' '));
            d.model = m.toStdString();
            break;
        }
        if (d.model.empty()) d.model = d.serial;
        found.push_back(std::move(d));
    }
    g_androids.swap(found);
}

void probeAndroid() {
    if (g_adb) return;   // a probe is already out

    const QString adb = androidTool("adb.exe");
    if (adb.isEmpty()) {
        g_androidStatus = "adb was not found beside BetterCast or on this PC";
        return;
    }

    // The lambdas hold the process they belong to rather than reading the
    // global. errorOccurred and finished can both fire, and by the time the
    // second arrives the global may already point at the next probe - acting
    // on that one would clear a result that has not happened yet.
    QProcess* p = new QProcess();
    g_adb = p;

    QObject::connect(p, &QProcess::finished,
                     [p](int code, QProcess::ExitStatus) {
                         const QString out =
                             QString::fromUtf8(p->readAllStandardOutput());
                         if (code == 0) {
                             parseAdbDevices(out);
                             g_androidStatus = g_androids.empty()
                                 ? std::string("no Android device on the cable yet")
                                 : "adb sees " + std::to_string(g_androids.size()) +
                                   (g_androids.size() == 1 ? " device" : " devices");
                         } else {
                             g_androidStatus = "adb exited with " + std::to_string(code);
                         }
                         if (g_adb == p) g_adb = nullptr;
                         p->deleteLater();
                         requestRedraw();
                     });
    QObject::connect(p, &QProcess::errorOccurred,
                     [p](QProcess::ProcessError) {
                         g_androidStatus = "adb could not be started";
                         if (g_adb == p) g_adb = nullptr;
                         p->deleteLater();
                         requestRedraw();
                     });
    p->start(adb, QStringList() << "devices" << "-l");
}

// ── Asking another device for its screen ─────────────────────────────────

// Where a sender listens for "please stream to me". Matches
// InviteListener::DefaultPort, which is this app's own implementation of the
// receiving half.
constexpr uint16_t kInvitePort = 51822;

// Long enough to cross a home network, short enough that a device which is
// simply not listening does not leave the button greyed out while the user
// waits to find out.
constexpr int kProbeTimeoutMs = 1500;

std::map<std::string, AskSupport> g_askSupport;

// One length-prefixed JSON frame. `mode` is extend, mirror, or probe - probe
// asks the other end to identify itself and start nothing.
QByteArray buildAskFrame(const char* mode) {
    QJsonObject obj;
    obj["type"]       = 99;    // InputEventType.command on the Mac
    obj["keyCode"]    = 770;   // device hello, the one InviteListener accepts
    obj["deviceName"] = QString::fromStdString(userName());
    obj["mode"]       = mode;
    // Dial back here. Named rather than assumed, because a receiver that had
    // to fall back to another port would otherwise never be reached.
    obj["port"]       = g_network ? int(g_network->actualTcpPort()) : 51820;

    const QByteArray payload = QJsonDocument(obj).toJson(QJsonDocument::Compact);
    QByteArray frame;
    QDataStream out(&frame, QIODevice::WriteOnly);
    out.setByteOrder(QDataStream::BigEndian);
    out << quint32(payload.size());
    frame.append(payload);
    return frame;
}

// Whether a reply came from BetterCast rather than from whatever else happened
// to be listening on that port.
//
// This exists because the first version of the probe treated "the TCP
// connection was accepted" as "this device can be asked", and something
// unrelated on the Mac accepts on this port. The buttons enabled themselves,
// the request went out, and it was read by a process that had no idea what it
// was. Only an answer in our own words counts.
bool isBetterCastAck(const QByteArray& buf) {
    if (buf.size() < 4) return false;
    QDataStream in(buf);
    in.setByteOrder(QDataStream::BigEndian);
    quint32 len = 0;
    in >> len;
    if (len == 0 || len > 8192) return false;
    if (quint32(buf.size()) < 4 + len) return false;   // still arriving

    const QJsonDocument doc = QJsonDocument::fromJson(buf.mid(4, int(len)));
    return doc.isObject() && doc.object().value("app").toString() == "BetterCast";
}

// Settings for one device, under a key of its own.
QString deviceKey(const std::string& name) {
    // A device name is free text - it can contain anything the owner typed,
    // including the slashes QSettings reads as group separators. Percent
    // encoding keeps one device's settings from landing inside another's.
    return QString::fromUtf8(
        QUrl::toPercentEncoding(QString::fromStdString(name)));
}

} // namespace

// Android-over-the-cable helpers, defined with the rest of that section below
// and called from init()'s signal handlers.
static void startCableReconnect();
static void enableWirelessAdbOnce();

bool init(int argc, char** argv) {
    if (g_app) return true;

    g_argc = argc;
    g_argv = argv;

    // Before QApplication, and the reason received video came through black.
    //
    // VideoRenderer uploads NV12 through fixed-function paths that a Core
    // profile context does not have; main.cpp of the Qt app sets this for
    // exactly that reason and says so. Without it the renderer gets whatever
    // Qt defaults to, the texture upload quietly fails and every frame paints
    // black - decoded fine, displayed as nothing.
    QSurfaceFormat fmt;
    fmt.setVersion(2, 1);
    fmt.setProfile(QSurfaceFormat::CompatibilityProfile);

    // No vsync on the receive window.
    //
    // Waiting for the display's next refresh costs up to a frame of latency by
    // itself, and worse than that: the swap happens inside processEvents on
    // the loop that also feeds the decoder and the socket, so a blocking swap
    // stalls the whole pipeline for the same 16ms the sleep was just lowered
    // to 2ms to avoid.
    //
    // The cost is tearing on a window showing another machine's desktop, where
    // being current matters more than being seamless. The glass UI is D3D11
    // and presents through its own path, so this does not touch it.
    fmt.setSwapInterval(0);
    QSurfaceFormat::setDefaultFormat(fmt);

    // QApplication rather than QCoreApplication, so widgets remain available
    // and the existing receive window keeps working untouched.
    g_app = std::make_unique<QApplication>(g_argc, g_argv);
    QCoreApplication::setApplicationName("BetterCast");
    QCoreApplication::setOrganizationName("BetterCast");

    QObject::connect(&LogManager::instance(), &LogManager::logAdded,
                     [](const QString& entry) {
                         g_lastLog = entry.toStdString();
                         g_logLines.push_back(g_lastLog);
                         // Bounded, because this runs for as long as the app is
                         // open and a stream logs steadily. Erasing from the
                         // front of a vector is fine at this rate and keeps the
                         // lines contiguous for the UI to walk.
                         if (g_logLines.size() > kLogScrollback) {
                             g_logLines.erase(g_logLines.begin(),
                                              g_logLines.begin() +
                                                  (long)(g_logLines.size() - kLogScrollback));
                         }
                         requestRedraw();
                     });

    g_discovery = std::make_unique<ServiceDiscovery>();
    QObject::connect(g_discovery.get(), &ServiceDiscovery::serviceFound,
                     [](const DiscoveredService&) { refreshDevices(); requestRedraw(); });
    QObject::connect(g_discovery.get(), &ServiceDiscovery::serviceLost,
                     [](const QString&) { refreshDevices(); requestRedraw(); });
    // Receive side. Without this Windows browses but never announces itself,
    // so it stops appearing on other devices as a screen they can extend to -
    // which is what the shipping app does at startup and the first version of
    // this bridge quietly dropped.
    g_decoder  = std::make_unique<VideoDecoder>();
    g_renderer = std::make_unique<VideoRenderer>();

    // Sound as well as picture. The macOS sender encodes system audio as AAC
    // and sends it down the same socket tagged 0x02; without a decoder wired
    // in, NetworkListener drops those packets and the stream arrives silent.
    // The Qt app has always done this - the bridge passed only the video half.
    g_audioDecoder = std::make_unique<AudioDecoder>();
    g_audioPlayer  = std::make_unique<AudioPlayer>();
    QObject::connect(g_audioDecoder.get(), &AudioDecoder::pcmDecoded,
                     g_audioPlayer.get(), &AudioPlayer::onPcmDecoded);

    // Decoded frames to the window that draws them.
    //
    // NetworkListener::setup() takes a renderer but only stores the pointer -
    // it never uses it, and this connection is what actually carries picture.
    // MainWindow makes it; the bridge did not, so every frame was decoded
    // correctly and emitted to nobody. Handing setup() the renderer looked
    // like wiring and was not.
    QObject::connect(g_decoder.get(), &VideoDecoder::frameDecoded,
                     g_renderer.get(), &VideoRenderer::onFrameDecoded);

    // Said once, so a log can tell "decoding but not drawing" from "not
    // decoding" without guessing. Those two look identical from outside and
    // cost several rounds to tell apart.
    QObject::connect(g_decoder.get(), &VideoDecoder::frameDecoded,
                     g_renderer.get(), [](AVFrame*) {
                         static bool said = false;
                         if (said) return;
                         said = true;
                         LogManager::instance().log(
                             "Glass: first decoded frame handed to the video window");
                     });

    g_network = std::make_unique<NetworkListener>();
    g_network->setup(g_decoder.get(), g_renderer.get(), g_audioDecoder.get());
    g_network->start();

    // The real receive window, not a bare renderer in a frame.
    //
    // VideoWindow is what the Qt app shows, and it carries the three things
    // that were missing: F11 and double-click for fullscreen, Escape to leave
    // it, and a toolbar. Showing the VideoRenderer widget directly gave a
    // window that could only ever display picture.
    g_input = std::make_unique<InputHandler>();
    g_input->attach(g_renderer.get());

    // And this is why clicks and typing did nothing: the renderer collects
    // them, but they only reach the other machine if the handler's events are
    // connected to the socket. Without it BetterCast is a viewer rather than a
    // second screen you can work on.
    QObject::connect(g_input.get(), &InputHandler::inputEvent,
                     g_network.get(), &NetworkListener::sendInputEvent);
    // An Android phone in Send mode ignores the events above. Over the cable it
    // can still be driven through adb, so while a cable stream is live the same
    // events go there as well.
    QObject::connect(g_input.get(), &InputHandler::inputEvent,
                     g_input.get(), [](const InputEvent& event) {
                         if (g_cableSession && g_adbInput &&
                             event.type != InputEventType::Command) {
                             g_adbInput->inject(event);
                         }
                     });
    QObject::connect(g_decoder.get(), &VideoDecoder::dimensionsChanged,
                     g_input.get(), [](int w, int h) {
                         // Pointer positions are sent in the stream's
                         // coordinates, so the handler has to know them or
                         // every click lands somewhere else.
                         if (w > 0 && h > 0) g_input->setContentSize(QSize(w, h));
                         if (w > 0 && h > 0) {
                             g_streamSize = QSize(w, h);
                             if (g_adbInput) g_adbInput->setStreamSize(w, h);
                         }
                     });
    // Picture arriving is what proves a reconnect worked; a tunnel that accepts
    // and then closes does not.
    QObject::connect(g_decoder.get(), &VideoDecoder::frameDecoded,
                     g_input.get(), [](AVFrame*) {
                         if (g_cableSession && g_cableReconnects != 0) {
                             g_cableReconnects = 0;
                             g_cableStatus = "connected over USB";
                             LogManager::instance().log("ADB: stream recovered");
                             requestRedraw();
                         }
                     });

    g_videoWindow = std::make_unique<VideoWindow>(g_renderer.get(), g_input.get());
    g_videoWindow->setWindowTitle("BetterCast - Receiving");
    QObject::connect(g_decoder.get(), &VideoDecoder::dimensionsChanged,
                     g_videoWindow.get(), [](int w, int h) {
                         if (w <= 0 || h <= 0 || !g_videoWindow) return;
                         LogManager::instance().log(
                             QString("Glass: video window sized to %1x%2").arg(w).arg(h));
                         g_videoWindow->resizeToFitVideo(w, h);
                     });

    const uint16_t port = g_network->actualTcpPort();
    g_discovery->startAdvertising(port);
    g_discovery->startBrowsing();

    // Show the video window only while something is actually sending, the way
    // the Qt app opens and closes it on connect.
    QObject::connect(g_network.get(), &NetworkListener::connectionEstablished,
                     []() {
                         g_receiving = true;
                         // showForVideo, not show: it also raises and focuses,
                         // which is what makes the keyboard reach the sender.
                         if (g_videoWindow) g_videoWindow->showForVideo();
                         requestRedraw();
                     });
    QObject::connect(g_network.get(), &NetworkListener::connectionLost,
                     []() {
                         g_receiving = false;
                         if (g_videoWindow) g_videoWindow->close();
                         requestRedraw();
                     });
    QObject::connect(g_network.get(), &NetworkListener::statusChanged,
                     [](const QString& m) { LogManager::instance().log(m); });

    // Outgoing dials report back to whichever panel started them: the cable
    // path dials localhost through adb, the Wi-Fi path dials the phone.
    QObject::connect(g_network.get(), &NetworkListener::connectFailed,
                     [](const QString& host, const QString& reason) {
                         const bool viaCable = host == QLatin1String("localhost");
                         const std::string hint = viaCable
                             ? " - is BetterCast on the phone sharing its screen?"
                             : " - check the address, and that BetterCast on the phone "
                               "is sharing its screen on the same network";
                         const std::string text = "could not connect: " + reason.toStdString() + hint;
                         if (viaCable) {
                             g_cableStatus = text;
                         } else if (!g_androidWifiHost.empty() &&
                                    host == QString::fromStdString(g_androidWifiHost)) {
                             g_androidWifiStatus = text;
                             g_androidWifiHost.clear();
                         }
                         requestRedraw();
                     });
    QObject::connect(g_network.get(), &NetworkListener::connectionEstablished, []() {
        if (!g_androidWifiHost.empty()) {
            g_androidWifiStatus = "connected to " + g_androidWifiHost;
            g_androidWifiHost.clear();
            requestRedraw();
        }
        if (g_cableSession && g_cableDialling) {
            g_cableDialling = false;
            if (g_cableReconnectTimer) g_cableReconnectTimer->stop();
            g_cableStatus = "connected over USB - click and type in the window to control the phone";
            enableWirelessAdbOnce();
            requestRedraw();
        }
    });
    QObject::connect(g_network.get(), &NetworkListener::connectFailed,
                     [](const QString& host, const QString&) {
                         if (host == QLatin1String("localhost")) g_cableDialling = false;
                     });
    QObject::connect(g_network.get(), &NetworkListener::connectionLost, []() {
        // Redial a dropped cable stream: the tunnel goes when the cable is
        // pulled, when adb switches to wireless, or when the phone's app
        // restarts. Not while a dial is already under way - connectTo() drops
        // the old socket first, which reports as a loss too.
        if (g_cableSession && !g_cableDialling) startCableReconnect();
    });

    LogManager::instance().log(
        QString("Glass: listening on port %1 and advertising to the network").arg(port));

#ifdef ENABLE_SENDER
    g_sender = std::make_unique<SenderController>();
    // Every one of these changes something the render loop cannot see, so each
    // has to ask for a frame or the UI sits on a stale picture until the user
    // happens to move the mouse.
    QObject::connect(g_sender.get(), &SenderController::sessionsChanged,
                     []() { requestRedraw(); });
    QObject::connect(g_sender.get(), &SenderController::error,
                     [](const QString& m) { LogManager::instance().log("Sender error: " + m); });
    QObject::connect(g_sender.get(), &SenderController::statusChanged,
                     [](const QString& m) { LogManager::instance().log(m); });
#endif

    // ── Hotspot ──────────────────────────────────────────────────────────
    g_hotspot = std::make_unique<HotspotManager>();
    QObject::connect(g_hotspot.get(), &HotspotManager::stateChanged,
                     [](const HotspotManager::Info&) { requestRedraw(); });
    QObject::connect(g_hotspot.get(), &HotspotManager::failed,
                     [](const QString& message) {
                         g_hotspotWanted = false;
                         LogManager::instance().log("Hotspot: " + message);
                         requestRedraw();
                     });

    // Windows turns the hotspot off by itself after roughly five minutes with
    // nobody connected, which HotspotManager's own header warns about: a
    // pairing screen that starts it once and waits for someone to walk to
    // their phone goes dead underneath the code it is showing. So keep it
    // armed rather than trusting it to stay up.
    g_hotspotTimer = new QTimer();
    g_hotspotTimer->setInterval(15000);
    QObject::connect(g_hotspotTimer, &QTimer::timeout, []() {
        if (!g_hotspot || !g_hotspotWanted) return;
        const auto info = g_hotspot->query();
        if (info.supported && !info.on) {
            LogManager::instance().log("Hotspot: Windows switched it off — starting it again");
            g_hotspot->start();
        }
    });
    g_hotspotTimer->start();

    // ── Android over the cable ───────────────────────────────────────────
    g_adbHelper = std::make_unique<AdbHelper>();
    QObject::connect(g_adbHelper.get(), &AdbHelper::statusChanged,
                     [](const QString& status) {
                         g_cableStatus = status.toStdString();
                         LogManager::instance().log(status);
                         requestRedraw();
                     });

    // The same launch-time donation prompt as the Qt app and the macOS app.
    // Deferred past the welcome splash, and queued rather than shown here: the
    // D3D window does not exist yet this early, and a timer only fires once
    // pump() is running, which is after it does. No Qt parent, so the dialog
    // keeps itself above the glass window.
    QTimer::singleShot(3000, []() { DonatePrompt::showIfDue(nullptr); });

    LogManager::instance().log("Glass: BetterCast core running inside the D3D11 loop");
    return true;
}

void pump() {
    if (!g_app) return;

    // Drain the queue, do not ration it.
    //
    // This used to cap at 4ms, on the theory that an unbounded processEvents
    // could stall the frame. That was wrong twice over: processEvents returns
    // as soon as the queue is empty, so there is nothing to run away with, and
    // the cap was actively harmful. Captured frames reach the encoder and the
    // socket through queued signals delivered on this thread, so 4ms out of
    // every 16 gave the whole streaming pipeline a 25% duty cycle. Three
    // receivers at 60fps is 180 frames a second through that gate, and the
    // backlog showed up as cursor lag that grew the longer a stream ran while
    // the picture itself stayed clean - a queue draining slower than it fills,
    // not a dropped-frame problem.
    QCoreApplication::processEvents(QEventLoop::AllEvents);
}

void requestRedraw() {
    g_redrawUntil = nowMs() + 400;   // a short burst, so an update animates in
}

bool shouldRender() {
#ifdef _WIN32
    const HWND active = GetActiveWindow();
    const bool foreground = active != nullptr && active == GetForegroundWindow();

    // Any cursor movement or button held counts as interaction. Polling this
    // avoids patching the upstream message loop to observe input.
    POINT cursor = {};
    GetCursorPos(&cursor);
    const bool moved = cursor.x != g_lastCursor.x || cursor.y != g_lastCursor.y;
    g_lastCursor = cursor;

    const bool pressed = (GetAsyncKeyState(VK_LBUTTON) & 0x8000) != 0 ||
                         (GetAsyncKeyState(VK_RBUTTON) & 0x8000) != 0;

    const uint64_t now = nowMs();
    if (moved || pressed || foreground != g_wasForeground) {
        g_lastActivity = now;
    }
    g_wasForeground = foreground;

    const bool interacting = foreground && (now - g_lastActivity) < 700;
    const bool wanted      = now < g_redrawUntil;

    if (interacting || wanted) {
        g_frameCap = 60;
        return true;
    }

    // Idle. Draw occasionally rather than never: a clock, a device appearing
    // or a stream ending should still show up without the user touching
    // anything, and a window that never repaints looks hung after a restore.
    const int intervalMs = foreground ? 200 : 1000;   // 5fps vs 1fps
    g_frameCap = 1000 / intervalMs;

    if (now - g_lastDraw >= (uint64_t)intervalMs) {
        g_lastDraw = now;
        return true;
    }

    // Sleep so the caller can skip without spinning.
    //
    // Much shorter while a stream is live in either direction: the sleep sets
    // how often pump() runs, and pump() is what moves frames between the
    // sockets, the codecs and the video window. At 16ms an idle-looking window
    // throttles a live stream to 60 drains a second; at 2ms it drains 500
    // times, comfortably ahead of anything either side sends.
    //
    // Receiving counts, and it did not. sessionCount() is senders only, so
    // watching a Mac's screen ran on the idle cadence - and worse, focusing
    // the video window makes this one background, which is the slowest branch
    // of all. The picture stayed smooth because whole frames still arrived;
    // the cursor did not, because a queue drained 60 times a second is 16ms
    // behind before anything else happens. Idle with nothing streaming keeps
    // the long sleep, since that is where the GPU saving comes from.
    const bool busy = sessionCount() > 0 || g_receiving;
    Sleep(busy ? 2 : 16);
    return false;
#else
    return true;
#endif
}

int currentFrameCap() {
    return g_frameCap;
}

void shutdown() {
    g_probe.reset();

    // Before Qt goes: a timer that fires during teardown would start an adb
    // process nobody is left to collect. g_adb is only non-null while no
    // deleteLater is pending for it, so deleting it here cannot double up.
    if (g_adbTimer) {
        g_adbTimer->stop();
        delete g_adbTimer;
        g_adbTimer = nullptr;
    }
    if (g_hotspotTimer) {
        g_hotspotTimer->stop();
        delete g_hotspotTimer;
        g_hotspotTimer = nullptr;
    }
    // Left running deliberately if it is up: the hotspot is a Windows setting,
    // not a thing this process owns, and someone who started one to pair a
    // phone does not expect closing the window to drop the phone off the
    // network. Windows switches it off on its own once nobody is connected.
    g_hotspot.reset();
    g_adbHelper.reset();
    if (g_adb) {
        g_adb->kill();
        g_adb->waitForFinished(1000);
        delete g_adb;
        g_adb = nullptr;
    }

#ifdef ENABLE_SENDER
    if (g_sender) {
        g_sender->stopAll();       // joins the capture threads before Qt goes
        g_sender.reset();
    }
#endif
    if (g_discovery) {
        g_discovery->stopBrowsing();
        g_discovery->stopAdvertising();
        g_discovery.reset();
    }
    g_network.reset();          // before the decoders it feeds
    // The window before the renderer it borrows. VideoWindow puts the renderer
    // in its layout and detaches it again in its destructor, deliberately, so
    // that whoever really owns it can still free it - but only if the window
    // goes first. The other order frees a widget that is still someone's child.
    g_videoWindow.reset();
    g_input.reset();
    g_renderer.reset();
    g_decoder.reset();
    g_audioPlayer.reset();
    g_audioDecoder.reset();
    g_app.reset();
}

const std::vector<Device>& devices() {
    return g_devices;
}

bool toggleProbeWindow() {
    if (!g_app) return false;

    if (g_probe) {
        g_probe.reset();
        LogManager::instance().log("Glass: closed the OpenGL probe window");
        return true;
    }

    // A bare QOpenGLWidget is enough to answer the question: the receive path
    // renders through one of these, and it has to survive alongside a D3D11
    // swapchain in the same process - on this hardware that means an Intel
    // panel driver and an NVIDIA card in the same address space.
    g_probe = std::make_unique<QOpenGLWidget>();
    g_probe->setWindowTitle("BetterCast - OpenGL coexistence probe");
    g_probe->resize(480, 270);
    g_probe->show();
    LogManager::instance().log("Glass: opened an OpenGL window beside the D3D11 one");
    return true;
}

bool probeWindowOpen() {
    return g_probe != nullptr;
}

std::string lastLogLine() {
    return g_lastLog;
}

// -- Identity -------------------------------------------------------------

std::string userName() {
    QSettings s("BetterCast", "BetterCast");
    // Falls back to the machine name, which is what mDNS advertises anyway, so
    // an untouched install shows something true rather than a placeholder.
    const QString fallback = QString("%1 (Windows)").arg(QSysInfo::machineHostName());
    return s.value("identity/name", fallback).toString().toStdString();
}

void setUserName(const std::string& name) {
    QSettings s("BetterCast", "BetterCast");
    s.setValue("identity/name", QString::fromStdString(name));
    requestRedraw();
}

std::string userHandle() {
    // The address other devices reach this machine on is more use under the
    // name than an invented handle.
    for (const QHostAddress& a : QNetworkInterface::allAddresses()) {
        if (a.protocol() == QAbstractSocket::IPv4Protocol && !a.isLoopback()) {
            return a.toString().toStdString();
        }
    }
    return "no network";
}

std::string userInitials() {
    const QString n = QString::fromStdString(userName()).trimmed();
    QString out;
    const QStringList parts = n.split(QChar(' '), Qt::SkipEmptyParts);
    for (const QString& part : parts) {
        if (!part.isEmpty() && part.at(0).isLetterOrNumber()) out += part.at(0).toUpper();
        if (out.size() == 2) break;
    }
    return out.isEmpty() ? std::string("BC") : out.toStdString();
}

// -- Settings -------------------------------------------------------------

std::string appVersion() {
    return UpdateChecker::currentVersion().toStdString();
}

std::string logFilePath() {
    return LogManager::instance().logFilePath().toStdString();
}

// SetupAPI walks every display device on the machine; not something to do sixty
// times a second from the render loop.
static VirtualDisplayNodes s_vddNodes;
static std::vector<VirtualDisplay> s_vdList;
static std::chrono::steady_clock::time_point s_vddNodesReadAt{};

// One refresh feeds both the counts and the per-display list.
static void refreshVirtualDisplays() {
#ifdef ENABLE_SENDER
    const auto now = std::chrono::steady_clock::now();
    if (s_vddNodesReadAt != std::chrono::steady_clock::time_point{} &&
        now - s_vddNodesReadAt <= std::chrono::seconds(3)) {
        return;
    }
    s_vddNodesReadAt = now;
    s_vddNodes = {};
    s_vdList.clear();
    if (!g_sender || !g_sender->vdd()) return;
    s_vddNodes.available = true;
    for (const auto& e : g_sender->virtualDisplays()) {
        if (e.present) s_vddNodes.present++;
        else s_vddNodes.disconnected++;
        VirtualDisplay vd;
        vd.instanceId   = e.instanceId.toStdString();
        vd.receiverName = e.receiverName.toStdString();
        vd.displayName  = e.displayName.toStdString();
        vd.present      = e.present;
        vd.inUse        = e.inUse;
        s_vdList.push_back(vd);
    }
#endif
}

VirtualDisplayNodes virtualDisplayNodes() {
    refreshVirtualDisplays();
    return s_vddNodes;
}

const std::vector<VirtualDisplay>& virtualDisplayList() {
    refreshVirtualDisplays();
    return s_vdList;
}

std::string virtualDisplayFor(const std::string& deviceName) {
    if (deviceName.empty()) return {};
    for (const auto& vd : virtualDisplayList()) {
        if (vd.receiverName == deviceName) return vd.instanceId;
    }
    return {};
}

bool removeVirtualDisplay(const std::string& instanceId) {
#ifdef ENABLE_SENDER
    if (!g_sender) return false;
    const bool ok = g_sender->removeVirtualDisplay(QString::fromStdString(instanceId));
    s_vddNodesReadAt = {};
    requestRedraw();
    return ok;
#else
    (void)instanceId;
    return false;
#endif
}

bool removeAllVirtualDisplays() {
#ifdef ENABLE_SENDER
    if (!g_sender || !g_sender->vdd()) return false;
    if (g_sender->isSending()) {
        LogManager::instance().log("Stop streaming before removing virtual displays - "
                                   "removing them ends every capture running on one");
        return false;
    }
    const bool ok = g_sender->vdd()->purgeVirtualDisplays();
    if (ok) g_sender->clearDisplayAssignments();   // nothing left to belong to anyone
    s_vddNodesReadAt = {};   // show the result on the next frame, not in 3 seconds
    requestRedraw();
    return ok;
#else
    return false;
#endif
}

const std::vector<std::string>& logLines() {
    return g_logLines;
}

// ── Asking another device for its screen ─────────────────────────────────

AskSupport askSupport(const std::string& host) {
    const auto it = g_askSupport.find(host);
    return it == g_askSupport.end() ? AskSupport::Unknown : it->second;
}

void probeAskSupport(const std::string& host) {
    if (host.empty()) return;
    if (g_askSupport.find(host) != g_askSupport.end()) return;   // already known or in flight

    g_askSupport[host] = AskSupport::Probing;

    auto* sock = new QTcpSocket();
    auto* timer = new QTimer();
    timer->setSingleShot(true);
    auto buf = std::make_shared<QByteArray>();

    // Connected, refused, answered and timed out all have to land exactly
    // once, and all of them have to clean up both objects. settle() is that
    // one place.
    auto settle = [sock, timer, host](AskSupport result) {
        if (g_askSupport[host] != AskSupport::Probing) return;   // already settled
        g_askSupport[host] = result;
        timer->stop();
        timer->deleteLater();
        sock->abort();
        sock->deleteLater();
        requestRedraw();
    };

    // Connecting is not the answer - it only says a socket accepted. Ask, and
    // wait to be answered in our own words.
    QObject::connect(sock, &QTcpSocket::connected,
                     [sock]() { sock->write(buildAskFrame("probe")); });
    QObject::connect(sock, &QTcpSocket::readyRead, [sock, buf, settle]() {
        buf->append(sock->readAll());
        if (isBetterCastAck(*buf)) settle(AskSupport::Yes);
        else if (buf->size() > 8192) settle(AskSupport::No);   // noise, not us
    });
    QObject::connect(sock, &QTcpSocket::errorOccurred,
                     [settle](QAbstractSocket::SocketError) { settle(AskSupport::No); });
    // Silence counts as no. Something that accepts and never answers is not
    // BetterCast, and that is the case this whole change exists for.
    QObject::connect(timer, &QTimer::timeout, [settle]() { settle(AskSupport::No); });

    timer->start(kProbeTimeoutMs);
    sock->connectToHost(QString::fromStdString(host), kInvitePort);
}

bool askToSend(const std::string& host, bool extend) {
    if (host.empty()) return false;

    // Blocking, deliberately: this is one small frame to a host that has
    // already answered a probe, it happens on a button press, and the
    // alternative is threading a result back through three callbacks to say
    // "sent". waitForConnected is bounded by the same timeout as the probe.
    QTcpSocket sock;
    sock.connectToHost(QString::fromStdString(host), kInvitePort);
    if (!sock.waitForConnected(kProbeTimeoutMs)) {
        g_askSupport[host] = AskSupport::No;
        LogManager::instance().log(
            QString("Glass: %1 did not answer on port %2, so it cannot be asked to send")
                .arg(QString::fromStdString(host)).arg(kInvitePort));
        requestRedraw();
        return false;
    }

    const char* mode = extend ? "extend" : "mirror";
    sock.write(buildAskFrame(mode));
    if (!sock.waitForBytesWritten(kProbeTimeoutMs)) {
        LogManager::instance().log(
            QString("Glass: could not send the request to %1").arg(QString::fromStdString(host)));
        requestRedraw();
        return false;
    }

    // Sent is not done. The first version logged success here, and it said so
    // four times while the bytes were being read by some unrelated process on
    // the Mac that had never heard of BetterCast. Wait to be answered.
    QByteArray buf;
    while (sock.waitForReadyRead(kProbeTimeoutMs)) {
        buf.append(sock.readAll());
        if (isBetterCastAck(buf)) break;
        if (buf.size() > 8192) break;
    }
    const bool acked = isBetterCastAck(buf);
    sock.disconnectFromHost();

    if (!acked) g_askSupport[host] = AskSupport::No;
    LogManager::instance().log(
        acked ? QString("Glass: asked %1 to %2 onto this PC")
                    .arg(QString::fromStdString(host), mode)
              : QString("Glass: %1 took the request but did not answer as BetterCast, "
                        "so nothing will happen - the Mac app cannot do this yet")
                    .arg(QString::fromStdString(host)));
    requestRedraw();
    return acked;
}

void openLogFile() {
    // fromLocalFile, not a hand-built file:// string: the path has spaces and
    // a drive letter in it, and QUrl is the thing that knows how to encode
    // those. Opens in whatever the user reads text with.
    QDesktopServices::openUrl(
        QUrl::fromLocalFile(LogManager::instance().logFilePath()));
}

std::vector<std::pair<std::string, std::string>> languages() {
    std::vector<std::pair<std::string, std::string>> out;
    for (const auto& e : Language::available()) {
        out.emplace_back(e.code.toStdString(), e.endonym.toStdString());
    }
    return out;
}

std::string savedLanguage() {
    return Language::savedCode().toStdString();
}

void setSavedLanguage(const std::string& code) {
    Language::setSavedCode(QString::fromStdString(code));
    LogManager::instance().log("Settings: language applies on next launch");
}

void checkForUpdates() {
    if (!g_updates) {
        g_updates = std::make_unique<UpdateChecker>();
        QObject::connect(g_updates.get(), &UpdateChecker::finished,
                         [](bool available, const QString& tag, const QString& url, const QString&) {
            g_updateUrl = url.toStdString();
            g_updateStatus = available
                ? QString("Update available: %1").arg(tag).toStdString()
                : QString("Up to date (%1)").arg(UpdateChecker::currentTag()).toStdString();
            requestRedraw();
        });
        QObject::connect(g_updates.get(), &UpdateChecker::failed, [](const QString& why) {
            // Quietly: BetterCast is often used on an isolated hotspot with no
            // internet, where a failed check is expected rather than wrong.
            g_updateStatus = QString("Could not check: %1").arg(why).toStdString();
            requestRedraw();
        });
    }
    g_updateStatus = "Checking...";
    g_updates->check();
}

std::string updateStatus() { return g_updateStatus; }
std::string updateUrl()    { return g_updateUrl; }

void openUrl(const std::string& url) {
    QDesktopServices::openUrl(QUrl(QString::fromStdString(url)));
}

void* appIconHandle() {
#ifdef _WIN32
    static HICON icon = nullptr;
    static bool tried = false;
    if (!tried) {
        tried = true;

        // Out of the executable's own resources first. Reading appicon.ico
        // from beside the exe was the original approach and it left the window
        // blank whenever the file was not where it was expected - and it can
        // never give Explorer an icon for the exe itself, because that comes
        // from the resource table and nowhere else.
        icon = LoadIconW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(kAppIconResourceId));

        if (!icon) {
            // Still support the loose file, so a build without the resource
            // script is not left iconless.
            const QString path =
                QFileInfo(QCoreApplication::applicationDirPath() + "/appicon.ico").absoluteFilePath();
            icon = (HICON)LoadImageW(nullptr, path.toStdWString().c_str(), IMAGE_ICON,
                                     0, 0, LR_LOADFROMFILE | LR_DEFAULTSIZE);
        }
        if (!icon) {
            LogManager::instance().log(
                "Glass: no app icon - neither the embedded resource nor appicon.ico "
                "beside the exe could be loaded");
        }
    }
    return icon;
#else
    return nullptr;
#endif
}

// ── Streaming ────────────────────────────────────────────────────────────

#ifdef ENABLE_SENDER
// The first stream's display setup restarts the display driver and adds
// monitors, so every screen goes black a few times. Say so before it happens
// rather than let it look like a crash. A native box, because this runs from
// the render loop; it blocks that loop while open, which is fine with nothing
// streaming yet.
static bool confirmDisplaySetup(const std::string& deviceName) {
    if (!g_sender || !g_sender->displaySetupPending(QString::fromStdString(deviceName))) {
        return true;
    }
#ifdef _WIN32
    const QString who = deviceName.empty() ? QString("this device")
                                           : QString::fromStdString(deviceName);
    const QString text = g_sender->isSending()
        ? QString("BetterCast needs to add a virtual display for %1.\n\n"
                  "Windows restarts its virtual displays to do that, so your screens "
                  "will flicker and devices already streaming will pause for a few "
                  "seconds before carrying on. Windows may ask for administrator "
                  "approval. This only happens the first time %1 needs a display.")
              .arg(who)
        : QString("BetterCast needs to set up a virtual display for %1.\n\n"
                  "Your screens will go black and flicker a couple of times while "
                  "Windows adds it, and Windows may ask for administrator approval. "
                  "This is normal, nothing is wrong, and it only happens the first "
                  "time.").arg(who);
    const int answer = MessageBoxW(
        GetActiveWindow(), text.toStdWString().c_str(),
        L"Setting up a virtual display",
        MB_OKCANCEL | MB_ICONINFORMATION | MB_SETFOREGROUND);
    if (answer != IDOK) {
        LogManager::instance().log("Glass: display setup declined - stream not started");
        return false;
    }
#endif
    return true;
}
#endif

bool startExtending(const std::string& host, uint16_t port,
                    int fps, int bitrateMbps, int width, int height,
                    const std::string& deviceName) {
#ifdef ENABLE_SENDER
    if (!g_sender) return false;
    if (!confirmDisplaySetup(deviceName)) return false;
    // Empty display name: the controller claims a virtual display for this
    // receiver, which is what extending means.
    const bool ok = g_sender->startSending(QString::fromStdString(host), port,
                                           fps, bitrateMbps, QString(), width, height,
                                           QString::fromStdString(deviceName));
    s_vddNodesReadAt = {};   // it may own a display now
    requestRedraw();
    return ok;
#else
    (void)host; (void)port; (void)fps; (void)bitrateMbps; (void)width; (void)height;
    (void)deviceName;
    return false;
#endif
}

bool startMirroring(const std::string& host, uint16_t port,
                    int fps, int bitrateMbps) {
#ifdef ENABLE_SENDER
    if (!g_sender) return false;
    const QString screen = mainDisplayName();
    if (screen.isEmpty()) {
        LogManager::instance().log("Glass: could not work out which display is the main "
                                   "one, so there is nothing to mirror");
        return false;
    }
    if (!confirmDisplaySetup(std::string())) return false;
    // Naming a real monitor is how the controller is told to mirror: it
    // captures that screen as it is, rather than claiming a virtual display
    // and resizing it. Size is deliberately not passed - the screen is already
    // whatever size it is, and changing that would resize the desktop.
    const bool ok = g_sender->startSending(QString::fromStdString(host), port,
                                           fps, bitrateMbps, screen, 0, 0);
    requestRedraw();
    return ok;
#else
    (void)host; (void)port; (void)fps; (void)bitrateMbps;
    return false;
#endif
}

bool isMirroring() {
#ifdef ENABLE_SENDER
    if (!g_sender) return false;
    const QString screen = mainDisplayName();
    if (screen.isEmpty()) return false;
    for (const QString& host : g_sender->activeReceivers()) {
        if (g_sender->displayForReceiver(host).compare(screen, Qt::CaseInsensitive) == 0)
            return true;
    }
    return false;
#else
    return false;
#endif
}

void stopSending(const std::string& host) {
#ifdef ENABLE_SENDER
    if (g_sender) g_sender->stopSending(QString::fromStdString(host));
    requestRedraw();
#else
    (void)host;
#endif
}

bool isSendingTo(const std::string& host) {
#ifdef ENABLE_SENDER
    return g_sender && g_sender->isSendingTo(QString::fromStdString(host));
#else
    (void)host; return false;
#endif
}

int sessionCount() {
#ifdef ENABLE_SENDER
    return g_sender ? g_sender->sessionCount() : 0;
#else
    return 0;
#endif
}

std::string displayForReceiver(const std::string& host) {
#ifdef ENABLE_SENDER
    if (!g_sender) return {};
    return g_sender->displayForReceiver(QString::fromStdString(host)).toStdString();
#else
    (void)host; return {};
#endif
}

std::string encoderInfo() {
#ifdef ENABLE_SENDER
    return g_sender ? g_sender->encoderInfo().toStdString() : std::string();
#else
    return {};
#endif
}

// ── Per-device stream settings ───────────────────────────────────────────

StreamSettings settingsFor(const std::string& deviceName) {
    StreamSettings out;
    if (deviceName.empty()) return out;
    QSettings s("BetterCast", "BetterCast");
    const QString k = "devices/" + deviceKey(deviceName) + "/";
    out.fps         = s.value(k + "fps",     out.fps).toInt();
    out.bitrateMbps = s.value(k + "bitrate", out.bitrateMbps).toInt();
    out.width       = s.value(k + "width",   out.width).toInt();
    out.height      = s.value(k + "height",  out.height).toInt();
    return out;
}

void setSettingsFor(const std::string& deviceName, const StreamSettings& v) {
    if (deviceName.empty()) return;
    QSettings s("BetterCast", "BetterCast");
    const QString k = "devices/" + deviceKey(deviceName) + "/";
    s.setValue(k + "fps",     v.fps);
    s.setValue(k + "bitrate", v.bitrateMbps);
    s.setValue(k + "width",   v.width);
    s.setValue(k + "height",  v.height);
}

// ── Receiving ────────────────────────────────────────────────────────────

std::string listeningOn() {
    if (!g_network) return "not listening";
    return "port " + std::to_string(g_network->actualTcpPort()) + " (TCP)";
}

std::string advertisedName() {
    if (!g_discovery) return {};
    const QString name = g_discovery->advertisedName();
    return name.isEmpty() ? std::string("not advertising yet") : name.toStdString();
}

bool isReceiving() {
    return g_receiving;
}

// ── Wi-Fi hotspot ────────────────────────────────────────────────────────

HotspotInfo hotspot() {
    static HotspotInfo cached;
    static uint64_t lastQuery = 0;

    // query() is described as cheap enough for the UI thread, which is true of
    // a click and not of sixty calls a second - the page reads this every
    // frame. A second is well inside how fast a phone can join.
    const uint64_t now = nowMs();
    if (lastQuery != 0 && now - lastQuery < 1000) return cached;
    lastQuery = now;

    if (!g_hotspot) return cached;
    const auto info = g_hotspot->query();

    HotspotInfo out;
    out.supported  = info.supported;
    out.on         = info.on;
    out.ssid       = info.ssid.toStdString();
    out.passphrase = info.passphrase.toStdString();
    out.clients    = info.clientCount;
    out.maxClients = info.maxClients;
    out.error      = info.error.toStdString();
    cached = out;
    return cached;
}

void setHotspot(bool on) {
    if (!g_hotspot) return;
    g_hotspotWanted = on;
    LogManager::instance().log(on ? "Hotspot: starting..." : "Hotspot: stopping...");
    if (on) g_hotspot->start();
    else    g_hotspot->stop();
    requestRedraw();
}

bool hotspotWanted() {
    return g_hotspotWanted;
}

const QrModules& hotspotQr() {
    static QrModules cached;
    static std::string cachedFor;

    const HotspotInfo hs = hotspot();
    if (!hs.on || hs.ssid.empty()) {
        cached = {};
        cachedFor.clear();
        return cached;
    }
    const std::string key = hs.ssid + '\n' + hs.passphrase;
    if (key == cachedFor) return cached;
    cachedFor = key;
    cached = {};

    // Modules rather than an image: the page draws them as rectangles, which
    // needs no texture upload into liquidDX11's renderer and stays sharp at
    // any window scale.
    try {
        const QByteArray payload = QrImage::wifiPayload(QString::fromStdString(hs.ssid),
                                                        QString::fromStdString(hs.passphrase))
                                       .toUtf8();
        const auto qr = qrcodegen::QrCode::encodeText(payload.constData(),
                                                      qrcodegen::QrCode::Ecc::MEDIUM);
        const int size = qr.getSize();
        cached.size = size;
        cached.modules.assign(static_cast<size_t>(size) * size, 0);
        for (int y = 0; y < size; y++) {
            for (int x = 0; x < size; x++) {
                cached.modules[static_cast<size_t>(y) * size + x] = qr.getModule(x, y) ? 1 : 0;
            }
        }
    } catch (...) {
        cached = {};
        LogManager::instance().log("Hotspot: could not encode the join code as a QR");
    }
    return cached;
}

// ── Android over the cable ───────────────────────────────────────────────

bool androidCableAvailable() {
    return g_adbHelper && g_adbHelper->isAvailable();
}

std::string androidCableStatus() {
    return g_cableStatus;
}

// Forward the port, then dial it - and set up adb control of the phone for the
// stream. `retry` is a reconnect attempt, which keeps the session alive when it
// fails rather than reporting a first-time failure.
static void startCableConnection(bool retry) {
    if (!g_adbHelper || !g_network || g_cableBusy) return;
    g_cableBusy = true;
    if (!retry) {
        g_cableStatus = "looking for a phone on the cable...";
        requestRedraw();
    }

    // Off the loop, because adb is run and waited on - up to ten seconds per
    // command. On this thread that is a frozen window and, worse, nothing
    // pumping the sockets.
    std::thread([retry]() {
        bool ok = false;
        uint16_t local = 0;
        QString adbPath;
        QString serial;
        QSize screen;
        {
            std::lock_guard<std::mutex> lock(g_adbMutex);
            ok = g_adbHelper->setupForward(51820);
            local = g_adbHelper->lastLocalPort();
            if (ok) {
                adbPath = g_adbHelper->findAdb();
                serial = g_adbHelper->deviceSerial();
                screen = g_adbHelper->screenSize();
            }
        }

        // Back to the Qt thread to touch the listener. g_network is the
        // context object, so if it is gone by then the call is simply dropped.
        QMetaObject::invokeMethod(g_network.get(), [ok, local, adbPath, serial, screen, retry]() {
            g_cableBusy = false;
            if (!retry && !ok) {
                g_cableStatus = "no Android device answered adb";
                LogManager::instance().log(
                    "ADB: no device answered - check the cable and that USB debugging is on");
                requestRedraw();
                return;
            }
            if (!ok) return;   // a failed retry; the reconnect timer tries again
            if (retry && !g_cableSession) return;   // stopped while adb was running

            g_cableSession = true;
            // A new injector each time: after the switch to wireless adb the
            // phone is a different adb device (ip:5555).
            g_adbInput = std::make_unique<AdbInputInjector>(adbPath, serial, screen);
            if (g_streamSize.isValid()) {
                g_adbInput->setStreamSize(g_streamSize.width(), g_streamSize.height());
            }
            if (!retry) {
                g_cableStatus = "tunnel ready on localhost:" + std::to_string(local);
            }
            LogManager::instance().log(
                QString("ADB: tunnel established, dialling localhost:%1").arg(local));
            g_cableDialling = true;
            g_network->connectTo("localhost", local);
            requestRedraw();
        }, Qt::QueuedConnection);
    }).detach();
}

static void endCableSession() {
    g_cableSession = false;
    g_cableDialling = false;
    g_cableReconnects = 0;
    if (g_cableReconnectTimer) g_cableReconnectTimer->stop();
    g_adbInput.reset();
}

static void startCableReconnect() {
    if (!g_cableReconnectTimer) {
        g_cableReconnectTimer = new QTimer();
        g_cableReconnectTimer->setInterval(kCableReconnectMs);
        QObject::connect(g_cableReconnectTimer, &QTimer::timeout, []() {
            if (!g_cableSession) {
                g_cableReconnectTimer->stop();
                return;
            }
            if (g_cableReconnects >= kCableReconnectMax) {
                LogManager::instance().log(
                    QString("ADB: auto-reconnect gave up after %1 attempts").arg(kCableReconnectMax));
                endCableSession();
                g_cableStatus = "reconnect failed - press Connect to try again";
                requestRedraw();
                return;
            }
            g_cableReconnects++;
            g_cableStatus = "reconnecting over adb (" + std::to_string(g_cableReconnects) +
                            "/" + std::to_string(kCableReconnectMax) + ")...";
            LogManager::instance().log(
                QString("ADB: reconnect attempt %1/%2").arg(g_cableReconnects).arg(kCableReconnectMax));
            requestRedraw();
            startCableConnection(true);
        });
    }
    if (g_cableReconnectTimer->isActive()) return;
    LogManager::instance().log("ADB: stream lost - will reconnect over adb");
    g_cableReconnectTimer->start();
}

// Once per session, a few seconds after the first cable stream connects:
// `adb tcpip 5555` + `adb connect`, so the cable can be unplugged and adb (and
// with it the stream and control) carries on over Wi-Fi. The switch drops the
// USB tunnel for a moment; the reconnect above picks the stream back up.
static void enableWirelessAdbOnce() {
    if (g_wirelessAdbTried || !g_adbHelper) return;
    g_wirelessAdbTried = true;
    QTimer::singleShot(5000, []() {
        if (!g_cableSession) return;
        std::thread([]() {
            bool ok = false;
            {
                std::lock_guard<std::mutex> lock(g_adbMutex);
                ok = g_adbHelper->enableWirelessAdb();
            }
            QMetaObject::invokeMethod(g_network.get(), [ok]() {
                LogManager::instance().log(ok
                    ? "ADB: wireless adb enabled - the cable can be unplugged"
                    : "ADB: wireless adb not enabled (is the phone on Wi-Fi?) - staying on the cable");
                if (ok && g_cableSession) {
                    g_cableStatus = "wireless adb on - you can unplug the cable";
                }
                requestRedraw();
            }, Qt::QueuedConnection);
        }).detach();
    });
}

bool receiveFromAndroidOverCable() {
    if (!g_adbHelper || !g_network || g_cableBusy) return false;
    endCableSession();
    g_wirelessAdbTried = false;
    startCableConnection(false);
    return true;
}

void stopAndroidCable() {
    const bool wasActive = g_cableSession;
    endCableSession();
    if (wasActive && g_network) g_network->disconnectAll();
    g_cableStatus = wasActive ? "stopped" : "";
    requestRedraw();
}

bool androidCableActive() {
    return g_cableSession;
}

// ── Android over Wi-Fi ───────────────────────────────────────────────────

std::string androidWifiAddress() {
    return QSettings("BetterCast", "BetterCast")
               .value("android/wifiAddress").toString().toStdString();
}

std::string androidWifiStatus() {
    return g_androidWifiStatus;
}

bool receiveFromAndroidOverWifi(const std::string& address) {
    if (!g_network) return false;
    endCableSession();   // a Wi-Fi stream is not a cable stream: no adb control, no redial

    const QString typed = QString::fromStdString(address).trimmed();
    QString hostText = typed;
    uint16_t port = 51820;   // TcpSender.DEFAULT_PORT in the Android app

    // "192.168.1.23:51820" - exactly one colon, so an IPv6 literal is not
    // mistaken for host:port (and is rejected below instead).
    if (typed.count(QLatin1Char(':')) == 1) {
        const int colon = typed.indexOf(QLatin1Char(':'));
        bool ok = false;
        const int p = typed.mid(colon + 1).toInt(&ok);
        if (!ok || p <= 0 || p > 65535) {
            g_androidWifiStatus = "that port is not a number between 1 and 65535";
            requestRedraw();
            return false;
        }
        port = static_cast<uint16_t>(p);
        hostText = typed.left(colon).trimmed();
    }

    QHostAddress parsed;
    if (hostText.isEmpty() || !parsed.setAddress(hostText) ||
        parsed.protocol() != QAbstractSocket::IPv4Protocol) {
        g_androidWifiStatus = "enter the phone's IP address, for example 192.168.1.23";
        requestRedraw();
        return false;
    }

    QSettings("BetterCast", "BetterCast").setValue("android/wifiAddress", typed);
    g_androidWifiHost = hostText.toStdString();
    g_androidWifiStatus = "connecting to " + g_androidWifiHost + ":" + std::to_string(port) + "...";
    LogManager::instance().log(
        QString("Android over Wi-Fi: dialling %1:%2").arg(hostText).arg(port));
    g_network->connectTo(hostText, port);
    requestRedraw();
    return true;
}

// ── Android over USB ─────────────────────────────────────────────────────

bool androidToolsPresent() {
    return !androidTool("scrcpy.exe").isEmpty() && !androidTool("adb.exe").isEmpty();
}

void watchAndroid(bool on) {
    g_androidWatching = on;
    if (!on) {
        if (g_adbTimer) g_adbTimer->stop();
        g_androids.clear();
        g_androidStatus.clear();
        requestRedraw();
        return;
    }

    if (!g_adbTimer) {
        g_adbTimer = new QTimer();
        QObject::connect(g_adbTimer, &QTimer::timeout, []() { probeAndroid(); });
    }
    // Often enough that plugging a cable in feels immediate, rarely enough
    // that this is not spawning a process every frame.
    g_adbTimer->start(3000);
    probeAndroid();
    requestRedraw();
}

bool androidWatching() {
    return g_androidWatching;
}

const std::vector<AndroidDevice>& androidDevices() {
    return g_androids;
}

bool mirrorAndroid(const std::string& serial) {
    const QString exe = androidTool("scrcpy.exe");
    if (exe.isEmpty()) {
        g_androidStatus = "scrcpy was not found beside BetterCast or on this PC";
        return false;
    }

    QStringList args;
    if (!serial.empty()) args << "-s" << QString::fromStdString(serial);
    args << "--window-title" << "BetterCast - Android";

    // Its own process and its own window, not a widget inside this one.
    // scrcpy pushes a server to the phone and decodes the stream itself;
    // wrapping that would mean reimplementing it, and it already works.
    //
    // Started in its own directory because that is where it looks for
    // scrcpy-server, which it has to push to the phone before anything
    // appears.
    const QString dir = QFileInfo(exe).absolutePath();
    const bool ok = QProcess::startDetached(exe, args, dir);
    g_androidStatus = ok ? "scrcpy started" : "scrcpy could not be started";
    LogManager::instance().log("Glass: " + QString::fromStdString(g_androidStatus) +
                               (serial.empty() ? QString()
                                               : " for " + QString::fromStdString(serial)));
    requestRedraw();
    return ok;
}

std::string androidStatus() {
    return g_androidStatus;
}

} // namespace BetterCastBridge
