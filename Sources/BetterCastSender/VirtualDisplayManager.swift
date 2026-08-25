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
    func createDisplay(resolution: Resolution, refreshRate: Int = 60) -> CGDirectDisplayID? {
        return createDisplay(
            width: resolution.width,
            height: resolution.height,
            ppi: resolution.ppi,
            hiDPI: resolution.hiDPI,
            name: resolution.name,
            refreshRate: refreshRate
        )
    }
    
    /// Creates a virtual display with custom parameters
    func createDisplay(width: Int, height: Int, ppi: Int, hiDPI: Bool, name: String, refreshRate: Int = 60) -> CGDirectDisplayID? {
        // Call the Objective-C function
        guard let display = createVirtualDisplay(
            Int32(width),
            Int32(height),
            Int32(ppi),
            hiDPI,
            name,
            serialNum,
            Int32(refreshRate)
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
