#pragma once

// Lets liquidDX11's D3D11 render loop drive BetterCast's real Qt core.
//
// Two things had to be true before this was possible, and both now are:
//
//   1. The core is widget-free. Capture, encode, the virtual display driver,
//      discovery and the network layer used to include MainWindow.h just to
//      reach LogManager, dragging QMainWindow in with it. Lifting LogManager
//      out means those objects can be linked by any front end.
//
//   2. A full QApplication, not QCoreApplication. Widgets stay available, so
//      the existing VideoWindow that shows received video keeps working
//      unchanged while the main UI is a native D3D11 window. Nothing about the
//      receive path needs porting, which was the objection that looked fatal.
//
// The glass loop owns the frame timing and calls pump() once per frame, which
// is where Qt's timers, sockets and queued signals actually run. No IPC, no
// second process, no serialisation boundary.
//
// Deliberately plain types across this seam: the page fragments are ImGui code
// including headers from a foreign project, and handing them QString or
// QObject would drag Qt's moc and include order into that world for nothing.

#include <cstdint>
#include <string>
#include <utility>
#include <vector>

namespace BetterCastBridge {

struct Device {
    std::string name;
    std::string host;
    uint16_t    port = 0;
};

// Creates the QApplication and starts mDNS browsing. Safe to call once.
bool init(int argc, char** argv);

// Run Qt's event loop for this frame, and throttle the frame rate when the
// window is not in front.
//
// Must be called from the render loop or nothing Qt-driven ever fires: no
// discovery, no sockets, no timers.
//
// The throttle is here rather than at another patch site because this is
// already called once per frame. liquidDX11 redraws continuously, which is
// right for a showcase and wrong for a utility that sits open all day - it
// measured around 50% of an integrated GPU doing nothing. A backgrounded
// window has nobody looking at it, so it does not need 60fps.
void pump();

// Whether this frame is worth drawing at all.
//
// The real saving is not a lower frame rate, it is not rendering. A utility
// that sits open all day changes nothing on screen for minutes at a time, and
// every frame it draws in that state is a GPU cycle spent on an identical
// image - the swapchain still shows the last frame presented, so skipping
// costs nothing visually.
//
// Sleeps before returning false, so the caller can `continue` without spinning
// the loop. Returns true whenever the user is interacting, the window has just
// come forward, or the core reports something new.
bool shouldRender();

// Frames per second the throttle is currently allowing, for the UI to show.
int currentFrameCap();

// Forces the next frame to draw. Call when something changes that the render
// loop cannot see for itself - a device appearing, a stream starting.
void requestRedraw();

void shutdown();

// Receivers seen on the network right now, newest state each call.
const std::vector<Device>& devices();

// ── Streaming ────────────────────────────────────────────────────────────
//
// The real SenderController, the same one the shipping app drives: DXGI
// duplication into a hardware H.264 encoder, one virtual display per
// receiver. Nothing here reimplements any of it.

// Extend onto a receiver: it gets a virtual display of its own, so the desktop
// grows rather than repeating. width/height of 0 means "match this PC".
//
// Returns false if no display could be claimed - see lastLogLine() for why,
// since the reasons are worth reading rather than reducing to a bool.
//
// deviceName is the receiver's name, so the display is remembered as its own
// and the same device gets it back next time.
bool startExtending(const std::string& host, uint16_t port,
                    int fps, int bitrateMbps, int width, int height,
                    const std::string& deviceName = std::string());

// Mirror this PC's main screen onto a receiver, the way the macOS sender's
// "Mirror Built-in" does. No virtual display is involved and nothing is
// resized, so what the receiver shows is what is on the monitor.
//
// Windows can duplicate a display only once, so a second receiver cannot
// mirror the same screen at the same time; that returns false with the reason
// in lastLogLine(). There is no size argument for the same reason - the screen
// is whatever size it already is.
bool startMirroring(const std::string& host, uint16_t port,
                    int fps, int bitrateMbps);

void stopSending(const std::string& host);
bool isSendingTo(const std::string& host);
int  sessionCount();

// Virtual display this receiver's stream is being captured from, empty when
// it is not streaming.
std::string displayForReceiver(const std::string& host);

// Encoder actually in use, e.g. "h264_nvenc". Empty until the first stream
// starts, because the encoder is probed at that point rather than up front.
std::string encoderInfo();

// Whether this PC's main screen is already going to some receiver, so the UI
// can say why mirroring to a second one is not on offer.
bool isMirroring();

// ── Per-device stream settings ───────────────────────────────────────────
//
// Remembered per device rather than globally, matching the macOS sender where
// clicking a connected display gives you that display's resolution and
// bitrate. A phone wants a different size from a laptop, and having set it
// once you should not have to set it again.
//
// Keyed by device name, not address: a phone that comes back tomorrow on a
// different IP is still the same phone and should keep its settings.

struct StreamSettings {
    int fps         = 60;
    int bitrateMbps = 20;
    int width       = 0;   // 0 = match this PC
    int height      = 0;
};

StreamSettings settingsFor(const std::string& deviceName);
void setSettingsFor(const std::string& deviceName, const StreamSettings& s);

// ── Receiving ────────────────────────────────────────────────────────────

// The port this PC is listening on, described for a person to read.
std::string listeningOn();

// The name other devices see. Assembled by ServiceDiscovery from the chosen
// name, the hostname and the platform keyword, so it is not the same thing as
// userName().
std::string advertisedName();

// Whether something is sending a screen here right now.
bool isReceiving();

// ── Wi-Fi hotspot ────────────────────────────────────────────────────────
//
// Streaming only needs both devices on one local network; it never touches the
// internet. On a network with client isolation - a hotel, a mall, a campus -
// that local path does not exist and nothing else in this app can work, so
// hosting an access point from this machine is the fix rather than a
// convenience.

struct HotspotInfo {
    bool supported = false;   // Windows answered at all
    bool on        = false;
    std::string ssid;
    std::string passphrase;   // what a phone needs to join
    int clients    = 0;
    int maxClients = 0;
    std::string error;        // why it is unsupported, when it is
};

// Cached and re-read about once a second, so it is safe to call every frame.
HotspotInfo hotspot();
void setHotspot(bool on);

// Whether the hotspot is meant to be on. Windows switches it off by itself
// after about five minutes with nobody connected, so this is what the re-arm
// timer checks - a pairing screen that started it once would otherwise go dead
// underneath the code it is showing.
bool hotspotWanted();

// The hotspot's join code, as QR modules for the page to draw: size x size,
// row by row, 1 = dark. The payload is the standard WIFI: format, the same one
// the Qt app shows, so a phone's own camera offers to join - nothing to type
// and nothing to install. Empty while the hotspot is off. Regenerated only
// when the network name or password changes, so safe to call every frame.
struct QrModules {
    int size = 0;
    std::vector<uint8_t> modules;
};
const QrModules& hotspotQr();

// ── Android over the cable ───────────────────────────────────────────────
//
// The opposite of the scrcpy panel below: this receives an Android phone's
// screen over USB, by forwarding a port through adb and dialling it, for when
// Wi-Fi discovery will not cooperate.

bool androidCableAvailable();
std::string androidCableStatus();
// Forwards the port through adb and dials it. While that stream is live the
// phone can be controlled from the receive window (taps, drags, Back, scroll,
// keys) through `adb shell input`; a few seconds in, adb is switched to
// wireless so the cable can be unplugged; and a dropped stream is redialled
// every 3 s, up to 15 times - the macOS receiver's behaviour.
bool receiveFromAndroidOverCable();
bool androidCableActive();
void stopAndroidCable();

// ── Android over Wi-Fi ───────────────────────────────────────────────────
//
// The same stream without the cable. The phone's Send mode listens on port
// 51820 and waits to be dialled, and it does not announce itself on the
// network, so its address is typed in - which is also how the macOS receiver
// does it. "192.168.1.23" or "192.168.1.23:51820". Remembered between runs.
// The stream is view-only: the phone's Send mode does not take input back.

std::string androidWifiAddress();
// False, with androidWifiStatus() saying why, if the address is not usable.
bool receiveFromAndroidOverWifi(const std::string& address);
std::string androidWifiStatus();

// ── Android over USB ─────────────────────────────────────────────────────
//
// The one feature that runs the other way. Everything else here sends this
// PC's screen somewhere; this shows an Android phone's screen on this PC,
// over the USB cable, using scrcpy and adb - the tools Google and Genymobile
// already ship for it, bundled beside the exe rather than reimplemented.
//
// adb is not run until asked. Starting it leaves a daemon behind on the
// machine, which is not something to do to someone who never opened this
// panel, so watching is something the user switches on.

struct AndroidDevice {
    std::string serial;
    std::string model;
    // adb's own word for it: "device" is ready, "unauthorized" means the
    // phone is waiting for its owner to accept this computer, "offline" means
    // the cable or the daemon is unhappy.
    std::string state;
};

bool androidToolsPresent();
void watchAndroid(bool on);
bool androidWatching();
const std::vector<AndroidDevice>& androidDevices();

// Opens the phone's screen in a window of its own. Returns false if it could
// not be launched; androidStatus() says why.
bool mirrorAndroid(const std::string& serial);

// The last thing adb or scrcpy had to say, for the UI to show.
std::string androidStatus();

// Proves an OpenGL widget and a D3D11 swapchain survive in one process, which
// is the one coexistence question the architecture rests on. Returns false if
// the window could not be created.
bool toggleProbeWindow();
bool probeWindowOpen();

// Last line the core logged, so the glass UI can show that real machinery is
// running behind it rather than mock data.
std::string lastLogLine();

// ── Identity ─────────────────────────────────────────────────────────────
//
// liquidDX11 ships a hardcoded demo account. BetterCast has no accounts and
// never will, but the chip is a good place for the name this machine
// advertises itself under, which is a real setting rather than decoration.

std::string userName();      // what this machine calls itself
std::string userHandle();    // shown under the name: the local address
std::string userInitials();  // for the avatar
void setUserName(const std::string& name);

// ── Settings ─────────────────────────────────────────────────────────────

std::string appVersion();          // e.g. "17.0.0"
std::string logFilePath();

// Recent log lines, oldest first, bounded.
//
// The app is a windowed binary, so there is no console behind it any more -
// this is where the log lives while it runs. The file keeps everything; this
// keeps enough to watch a stream start and fail without leaving the app.
const std::vector<std::string>& logLines();

// Opens the log file in whatever the user reads text with.
void openLogFile();

// ── Virtual displays ─────────────────────────────────────────────────────
//
// Every install and every pool build used to be able to leave display driver
// nodes behind, and disconnected ones never went away. These let the settings
// page show how many there are and clear them.

struct VirtualDisplayNodes {
    bool available    = false;  // sender built in, so the driver can be asked
    int  present      = 0;      // nodes whose monitor can come up
    int  disconnected = 0;      // leftovers with no device behind them
};

// Cached and re-read every few seconds, so it is safe to call every frame.
VirtualDisplayNodes virtualDisplayNodes();

// Removes every virtual display node, disconnected ones included, behind one
// UAC prompt. Blocks until the prompt is answered. Refuses while anything is
// streaming, since it would end those captures; lastLogLine() says why.
bool removeAllVirtualDisplays();

// One entry per virtual display, with the receiver it belongs to. Windows names
// them all "VDD by MTT"; the receiver name is BetterCast's own record.
struct VirtualDisplay {
    std::string instanceId;    // ROOT\DISPLAY\000N
    std::string receiverName;  // empty when unassigned
    std::string displayName;   // \\.\DISPLAYn, empty when detached or gone
    bool present = true;       // false for a disconnected leftover
    bool inUse   = false;      // being streamed right now
};

// Cached with virtualDisplayNodes(), so safe to call every frame.
const std::vector<VirtualDisplay>& virtualDisplayList();

// The node id of a receiver's own virtual display, empty if it has none.
std::string virtualDisplayFor(const std::string& deviceName);

// Removes one virtual display behind one UAC prompt. Refuses while anything
// streams to a virtual display, for the same reason as removing all of them.
bool removeVirtualDisplay(const std::string& instanceId);

// ── Asking another device for its screen ─────────────────────────────────
//
// The reverse of everything else here: instead of sending this PC's screen
// out, this asks a Mac to send its screen to this PC, so the Mac never has to
// be touched. Extend gives this PC its own virtual display over there; Mirror
// duplicates the Mac's main screen.
//
// The request travels to the sender's invite port as
// [4B big-endian length][JSON], carrying `type` 99 and `keyCode` 770 - the
// shape InviteListener on this side already accepts - plus the mode and the
// port to dial back on.
//
// This only works against a sender that listens for it, and as of BetterCast
// 18 the macOS app does not. Rather than offer a button that fails, the UI
// asks first: whoever is listening on the invite port can be asked, and
// whoever is not is shown as not ready. That means the day the Mac gains the
// listener, this side needs no change at all.

enum class AskSupport {
    Unknown,   // not looked at yet
    Probing,   // asking now
    Yes,       // something is listening and can be asked
    No         // nothing there
};

AskSupport askSupport(const std::string& host);

// Starts a probe if this host has not been looked at. Cheap and cached, so it
// is safe to call from the render loop.
void probeAskSupport(const std::string& host);

// Ask that device to start sending to this PC. `extend` picks a virtual
// display over there; false mirrors its main screen.
bool askToSend(const std::string& host, bool extend);

// Language codes and their names in their own language, for the picker.
std::vector<std::pair<std::string, std::string>> languages();
std::string savedLanguage();                       // empty means follow system
void setSavedLanguage(const std::string& code);

// Kicks off a GitHub Releases check; the result arrives in updateStatus().
void checkForUpdates();
std::string updateStatus();
std::string updateUrl();
void openUrl(const std::string& url);

// Window icon for the app, so the taskbar shows BetterCast rather than the
// generic default. Returns an HICON as void* to keep Windows types out of
// this header. Null when the icon file is not beside the executable.
void* appIconHandle();

} // namespace BetterCastBridge
