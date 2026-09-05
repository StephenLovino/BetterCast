#pragma once
// Note: this file is only compiled on Windows (gated by ENABLE_SENDER + WIN32).

#include <QObject>
#include <QString>
#include <QSize>
#include <QVector>

// Manages Virtual Display Driver (VDD) integration.
// Detects VDD installation, creates/removes virtual monitors,
// and enumerates available DXGI outputs for capture selection.
class VirtualDisplayVDD : public QObject {
    Q_OBJECT
public:
    explicit VirtualDisplayVDD(QObject* parent = nullptr);
    ~VirtualDisplayVDD() override;

    struct MonitorInfo {
        int adapterIndex;
        int outputIndex;
        QString name;        // e.g. "\\.\DISPLAY1"
        QString adapterName; // e.g. "NVIDIA GeForce RTX 3080"
        int width;
        int height;
        bool isVirtual;      // true if this is a VDD virtual display
        // Attached to the desktop, i.e. it has a framebuffer to capture.
        //
        // Do NOT infer this from width/height: EnumDisplaySettings with
        // ENUM_REGISTRY_SETTINGS returns the last persisted mode for a display
        // that is currently detached, so a dead monitor happily reports
        // 1920x1080. Only DISPLAY_DEVICE_ATTACHED_TO_DESKTOP is authoritative.
        bool attached = true;
    };

    struct VddResolution {
        int width;
        int height;
        int refreshRate;
    };

    // Snapshot of the desktop's display topology.
    //
    // In CCD terms a "clone" (what Display Settings calls "Duplicate these
    // displays") is two active paths that share one source — one framebuffer
    // driving several monitors. Extend gives every target its own source.
    struct TopologyState {
        bool valid = false;         // the CCD query succeeded
        bool anyCloned = false;     // some source drives more than one target
        bool virtualCloned = false; // a virtual display is one of the clones
        bool virtualActive = false; // a virtual target is attached to the desktop
        int activePaths = 0;
        QString describe() const;
    };

    // VDD detection
    bool isVddInstalled() const;
    QString vddInstallPath() const;
    void refreshInstallStatus();  // re-run detection (e.g. after user installs VDD)

    // Virtual display management
    // allowUiHelper: launch VDD Control to use its named pipe. That pops the
    // driver's console over the desktop and waits ten seconds for it, so the
    // automatic path passes false and relies on the settings file instead.
    bool createVirtualDisplay(int width = 1920, int height = 1080, int refreshRate = 60,
                              bool allowUiHelper = true);
    bool removeVirtualDisplay(int index = -1); // -1 = remove last
    bool removeAllVirtualDisplays();
    int virtualDisplayCount() const;

    // Monitor enumeration (all monitors — real + virtual)
    QVector<MonitorInfo> enumerateMonitors() const;

    // Find the output index for a virtual display
    int findVirtualDisplayOutput() const;

    // The four modes Win+P offers. Windows applies these through one call, so
    // exposing them in-app saves a trip to Display Settings.
    enum class Topology { Extend, Duplicate, InternalOnly, ExternalOnly };
    bool applyTopology(Topology mode);
    static QString topologyName(Topology mode);

    // A root-enumerated VDD device node. Each node contributes one virtual
    // monitor — they are NOT described by the settings XML, which is why
    // rewriting that file cannot remove them.
    struct VddDevice {
        QString instanceId;    // e.g. "ROOT\\DISPLAY\\0001"
        QString friendlyName;
    };
    QVector<VddDevice> enumerateVddDevices() const;

    // Add another VDD device node. On this driver one node == one monitor, and
    // creating a node needs administrator rights, so this raises a single UAC
    // prompt. Writing vdd_settings.xml does NOT add monitors here.
    bool addVddDeviceNode();

    // Add several nodes behind one UAC prompt. Installing a node makes the
    // driver re-enumerate every monitor it owns, so device names change and any
    // capture running against one of them dies — do the whole pool at once,
    // while nothing is streaming, rather than one node per receiver.
    bool addVddDeviceNodes(int count);

    // Bring the pool up to `desired` nodes, doing nothing if it is already
    // there. Returns true if the pool ends up at or above `desired`.
    bool ensureDisplayNodes(int desired);

    // Block until the driver has actually published `expected` virtual monitors,
    // or the timeout runs out. A device node exists several seconds before its
    // monitor does, and attaching in that window fails with DISP_CHANGE_FAILED.
    bool waitForVirtualMonitors(int expected, int timeoutMs = 20000) const;

    // Remove VDD device nodes, keeping the first `keep` of them.
    // Requires administrator rights, so this triggers a single UAC prompt
    // rather than elevating the whole app.
    bool removeVddDevices(int keep = 0);

    // Attach a specific virtual display to the desktop and place it beside the
    // others. A VDD device node can exist while its monitor is detached — it
    // then reports 0x0 and has no framebuffer, so capturing it yields nothing.
    // width/height of 0 means "use the preferred resolution", which defaults to
    // whatever the primary display is running at.
    bool attachVirtualDisplay(const QString& deviceName,
                              int width = 0, int height = 0, int refreshRate = 60);

    // Resolution virtual displays should run at. Windows brings an extended VDD
    // monitor up at the driver default of 800x600, so without this the stream
    // goes out at 800x600 regardless of what was requested.
    void setPreferredResolution(int width, int height) {
        if (width > 0 && height > 0) { m_preferredWidth = width; m_preferredHeight = height; }
    }

    // Raise a virtual display to a resolution the driver advertises.
    bool setVirtualDisplayResolution(const QString& deviceName, int width, int height);

    // Make sure the driver OFFERS this resolution at all.
    //
    // vdd_settings.xml lists the modes the virtual monitors advertise. With an
    // empty list the driver falls back to 800x600, and every attempt to set
    // anything larger is refused - which is why second displays streamed at
    // 800x600 no matter what the mode-setting code did. Restarts the driver, so
    // call it at startup, never mid-stream.
    bool ensureResolutionAdvertised(int width, int height);

    // Advertise several modes in one pass.
    //
    // Every size a virtual display may be asked to run at has to be in
    // vdd_settings.xml first, and writing that file needs elevation and
    // restarts the driver. Doing it per device would mean a UAC prompt and a
    // display flicker every time someone picked a different resolution, so the
    // whole menu goes in once, before anything streams.
    bool ensureResolutionsAdvertised(const QVector<QSize>& modes);

    // The sizes offered in the per-device resolution picker.
    static QVector<QSize> commonResolutions();

    // The primary display's current resolution, so virtual displays can default
    // to matching the real screen rather than the driver's 800x600.
    static QSize primaryResolution();

    // Display topology
    TopologyState queryTopology() const;

    // Force the desktop out of mirrored mode and place the virtual display
    // beside the primary. No-op (but still repositions) when already extended.
    // This is what Display Settings → "Extend these displays" does.
    bool ensureExtendedTopology();

signals:
    void virtualDisplayCreated(int outputIndex);
    void virtualDisplayRemoved();
    void error(const QString& message);
    void statusChanged(const QString& status);

private:
    bool detectVddInstall();
    bool isDriverLoaded() const;
    bool installDriver();
    bool ensureVddControlRunning();
    bool activateVirtualDisplay();
    bool applyExtendTopology();          // SDC_TOPOLOGY_EXTEND — the Win+P route
    bool applyExtendTopologySupplied();  // explicit one-source-per-target path set
    bool positionVirtualDisplay();       // place it to the right of the primary

    // Topology changes re-apply a saved mode to every display, the primary
    // included. Capture before, restore after, so extending a desktop never
    // silently alters the screen the user is looking at.
    void capturePrimaryMode();
    void restorePrimaryMode();   // retained but no longer called — see ensureExtendedTopology
    int m_preferredWidth = 1920;
    int m_preferredHeight = 1080;
    // Opaque storage for a Win32 DEVMODEW; sized generously and checked with a
    // static_assert in the .cpp so this header need not include Windows.h.
    unsigned char m_savedPrimaryMode[256] = {};
    bool m_havePrimaryMode = false;
    bool writeVddSettings(const QVector<VddResolution>& displays);
    QVector<VddResolution> readVddSettings() const;

    /// Full path of the file the driver actually reads, which is not the copy
    /// sitting in whichever folder the driver package was installed from.
    QString vddSettingsPath() const;
    bool notifyDriverRefresh();
    bool tryNamedPipe(const QString& command);

    QString m_vddPath;
    bool m_vddInstalled = false;
    int m_createdDisplayCount = 0;
};
