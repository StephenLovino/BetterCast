import Foundation
import CoreGraphics
import VirtualDisplayLib

/// Swift wrapper for the Objective-C VirtualDisplay functionality
/// Uses private CoreGraphics APIs to create virtual displays
class VirtualDisplayManager {
    
    struct Resolution: Hashable {
        let width: Int
        let height: Int
        let ppi: Int
        let hiDPI: Bool
        let name: String
    }
    
    static let defaultResolutions: [Resolution] = [
        Resolution(width: 1280, height: 720, ppi: 92, hiDPI: false, name: "1280 x 720 (HD)"),
        Resolution(width: 1920, height: 1080, ppi: 102, hiDPI: false, name: "1920 x 1080 (FHD)"),
        Resolution(width: 1920, height: 1200, ppi: 113, hiDPI: false, name: "1920 x 1200 (16:10)"),
        Resolution(width: 2560, height: 1440, ppi: 109, hiDPI: false, name: "2560 x 1440 (2K)"),
        Resolution(width: 2560, height: 1600, ppi: 227, hiDPI: true, name: "2560 x 1600 (16:10)"),
        Resolution(width: 3840, height: 2160, ppi: 163, hiDPI: false, name: "3840 x 2160 (4K)"),
        // The TargetBridge use case: a 5K iMac panel as the receiver. 218 ppi is the
        // panel's native density; hiDPI renders the desktop at a 2560x1440 Retina
        // look, which is what makes text native-sharp on that glass. Streams this
        // size exceed H.264 encoder limits and are promoted to HEVC automatically.
        Resolution(width: 5120, height: 2880, ppi: 218, hiDPI: true, name: "5120 x 2880 (5K Retina)"),
        Resolution(width: 1440, height: 900, ppi: 127, hiDPI: false, name: "1440 x 900 (16:10)"),
    ]

    /// Bounds for a user-entered size. The floor keeps macOS from refusing the mode;
    /// the ceiling is the 5K preset's long side so Retina (which doubles it) stays
    /// within what CGVirtualDisplay and the encoders accept.
    static let customSizeRange = 640...5120
    
    struct Size: Equatable {
        let width: Int
        let height: Int
    }

    /// Divisors of the streamed pixel size offered as HiDPI "looks like" modes: 2.5 is
    /// the largest text, 1.0 the most space (one point per streamed pixel).
    static let scaleFactors: [Double] = [2.5, 2.0, 1.75, 1.5, 1.25, 1.0]

    /// The "looks like" size, in points, of `native` pixels shown at `factor`.
    static func looksLike(native: Size, factor: Double) -> Size {
        Size(width: Int((Double(native.width) / factor).rounded()) & ~1,
             height: Int((Double(native.height) / factor).rounded()) & ~1)
    }

    /// The text sizes a display streaming at `native` pixels can offer. Sizes too small
    /// to be usable (a phone in landscape at 2.5x) are left out.
    static func textSizeOptions(native: Size) -> [(factor: Double, size: Size)] {
        scaleFactors
            .map { ($0, looksLike(native: native, factor: $0)) }
            .filter { min($0.1.width, $0.1.height) >= 480 }
    }

    /// The modes for a HiDPI display that streams at `native` pixels and starts at
    /// `initial` points. Every mode keeps the native aspect ratio, and the encoder keeps
    /// capturing at `native` whichever one is picked, so choosing a size only changes how
    /// big the UI looks, never the stream's sharpness.
    static func scaledModes(native: Size, initial: Size) -> [Size] {
        var modes = [initial]
        for option in textSizeOptions(native: native) {
            // Rounding can land a pixel off the initial mode; don't list it twice.
            guard !modes.contains(where: { abs($0.width - option.size.width) <= 2 && abs($0.height - option.size.height) <= 2 }) else { continue }
            modes.append(option.size)
        }
        return modes
    }

    private static var nextSerialNum: UInt32 = 1

    /// Serials handed out this session, so two live displays never collide.
    private static var serialsInUse: Set<UInt32> = []
    private static let serialDefaultsKey = "setting.displaySerials"

    private var activeDisplay: Any?
    private(set) var displayID: CGDirectDisplayID?
    private let serialNum: UInt32

    /// - Parameter deviceKey: the receiver's service name. Passing it is what makes
    ///   the display keep its place in System Settings; passing nil falls back to the
    ///   old throwaway counter.
    ///
    /// macOS keys saved display arrangement on vendor/product/serial. The serial used
    /// to be a counter starting at 1 that reset every launch and incremented on every
    /// reconnect, so the OS saw a brand new monitor each time and dropped it in the
    /// default slot to the right of the built-in screen. Worse, a single connection
    /// burns two of them: the display is created at the configured size, then rebuilt
    /// once the device reports its own. Deriving the serial from the device instead
    /// means the same iPhone is the same monitor every time, and the position the user
    /// dragged it to sticks.
    init(deviceKey: String? = nil) {
        guard let deviceKey = deviceKey, !deviceKey.isEmpty else {
            self.serialNum = VirtualDisplayManager.nextSerialNum
            VirtualDisplayManager.nextSerialNum += 1
            return
        }
        self.serialNum = VirtualDisplayManager.stableSerial(for: deviceKey)
    }

    /// A serial that is the same for this device on every launch, and different from
    /// every other display currently up.
    private static func stableSerial(for deviceKey: String) -> UInt32 {
        var stored = (UserDefaults.standard.dictionary(forKey: serialDefaultsKey) as? [String: Int]) ?? [:]

        if let existing = stored[deviceKey].map({ UInt32(truncatingIfNeeded: $0) }),
           !serialsInUse.contains(existing) {
            serialsInUse.insert(existing)
            return existing
        }

        // First time seeing this device, or its usual serial is taken by a display that
        // is still up (two receivers with the same name). Find the next free one.
        var candidate = hash(deviceKey)
        let taken = Set(stored.values.map { UInt32(truncatingIfNeeded: $0) })
        while serialsInUse.contains(candidate) || taken.contains(candidate) {
            candidate = candidate &+ 1
            if candidate == 0 { candidate = 1 }
        }

        stored[deviceKey] = Int(candidate)
        UserDefaults.standard.set(stored, forKey: serialDefaultsKey)
        serialsInUse.insert(candidate)
        return candidate
    }

    /// FNV-1a. Any stable hash would do; Swift's `hashValue` is deliberately seeded
    /// per process, so it is the one thing that cannot be used here.
    private static func hash(_ s: String) -> UInt32 {
        var h: UInt32 = 2166136261
        for byte in s.utf8 {
            h ^= UInt32(byte)
            h = h &* 16777619
        }
        return h == 0 ? 1 : h
    }

    /// Whether this instance is the one currently holding `serialNum`.
    ///
    /// Teardown runs twice: `destroyDisplay()` explicitly, then again from `deinit`.
    /// Between those two the rebuilt display has usually already claimed the same
    /// serial, so an unguarded release would free a number that is back in use.
    private var holdsSerial: Bool = true

    /// Release this display's serial so a later connection from the same device can
    /// reuse it. Called when the display is torn down.
    private func releaseSerial() {
        guard holdsSerial else { return }
        holdsSerial = false
        VirtualDisplayManager.serialsInUse.remove(serialNum)
    }
    
    /// Creates a virtual display with the specified resolution
    /// - Returns: The CGDirectDisplayID of the created virtual display, or nil if creation failed
    /// - Parameter scaledModes: "looks like" sizes in points to offer in System Settings,
    ///   the first being the starting one; empty for the single mode `resolution` implies.
    func createDisplay(resolution: Resolution, refreshRate: Int = 60, scaledModes: [Size] = []) -> CGDirectDisplayID? {
        return createDisplay(
            width: resolution.width,
            height: resolution.height,
            ppi: resolution.ppi,
            hiDPI: resolution.hiDPI,
            name: resolution.name,
            refreshRate: refreshRate,
            scaledModes: scaledModes
        )
    }
    
    /// Creates a virtual display with custom parameters
    func createDisplay(width: Int, height: Int, ppi: Int, hiDPI: Bool, name: String, refreshRate: Int = 60, scaledModes: [Size] = []) -> CGDirectDisplayID? {
        // Call the Objective-C function
        guard let display = createVirtualDisplay(
            Int32(width),
            Int32(height),
            Int32(ppi),
            hiDPI,
            name,
            serialNum,
            Int32(refreshRate),
            scaledModes.map { [NSNumber(value: $0.width), NSNumber(value: $0.height)] }
        ) else {
            LogManager.shared.log("VirtualDisplayManager: Failed to create virtual display")
            return nil
        }
        
        activeDisplay = display
        
        // Get the display ID from the created virtual display
        // The CGVirtualDisplay object has a displayID property
        if let displayIDValue = (display as AnyObject).value(forKey: "displayID") as? UInt32 {
            self.displayID = displayIDValue
            LogManager.shared.log("VirtualDisplayManager: Created virtual display with ID \(displayIDValue)")
            return displayIDValue
        }
        
        LogManager.shared.log("VirtualDisplayManager: Created display but couldn't get ID")
        return nil
    }
    
    /// The size the display currently looks like, in points.
    var currentLooksLike: Size? {
        guard let id = displayID, let mode = CGDisplayCopyDisplayMode(id) else { return nil }
        return Size(width: mode.width, height: mode.height)
    }

    /// Switches to the mode that looks like `size`, preferring its HiDPI variant. Takes
    /// effect without rebuilding the display, so the stream keeps running.
    @discardableResult
    func switchMode(to size: Size) -> Bool {
        guard let id = displayID else { return false }
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []
        guard let mode = modes
            .filter({ $0.width == size.width && $0.height == size.height })
            .max(by: { $0.pixelWidth < $1.pixelWidth }) else {
            LogManager.shared.log("VirtualDisplayManager: No \(size.width)x\(size.height) mode on display \(id)")
            return false
        }
        let err = CGDisplaySetDisplayMode(id, mode, nil)
        LogManager.shared.log("VirtualDisplayManager: Switch display \(id) to \(size.width)x\(size.height): \(err == .success ? "ok" : "error \(err.rawValue)")")
        return err == .success
    }

    /// Destroys the currently active virtual display
    func destroyDisplay() {
        activeDisplay = nil
        displayID = nil
        releaseSerial()
        LogManager.shared.log("VirtualDisplayManager: Destroyed virtual display")
    }
    
    deinit {
        destroyDisplay()
    }
}

extension VirtualDisplayManager.Resolution {
    /// A size the presets don't cover — foldables and other odd aspect ratios that
    /// would otherwise be letterboxed. Dimensions are clamped to `customSizeRange` and
    /// rounded down to even, since H.264/HEVC reject odd frame sizes.
    static func custom(width: Int, height: Int) -> Self {
        let range = VirtualDisplayManager.customSizeRange
        func fit(_ v: Int) -> Int { min(max(v, range.lowerBound), range.upperBound) & ~1 }
        let w = fit(width), h = fit(height)
        return Self(width: w, height: h, ppi: 110, hiDPI: false, name: "\(w) x \(h) (\(tr("Custom")))")
    }

    /// True when this size isn't one of `defaultResolutions`.
    var isCustom: Bool {
        !VirtualDisplayManager.defaultResolutions.contains { $0.width == width && $0.height == height }
    }
}
