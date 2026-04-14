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
        Resolution(width: 1440, height: 900, ppi: 127, hiDPI: false, name: "1440 x 900 (16:10)"),
    ]
    
    private static var nextSerialNum: UInt32 = 1

    private var activeDisplay: Any?
    private(set) var displayID: CGDirectDisplayID?
    private let serialNum: UInt32

    init() {
        self.serialNum = VirtualDisplayManager.nextSerialNum
        VirtualDisplayManager.nextSerialNum += 1
    }
    
    /// Creates a virtual display with the specified resolution
    /// - Returns: The CGDirectDisplayID of the created virtual display, or nil if creation failed
    func createDisplay(resolution: Resolution) -> CGDirectDisplayID? {
        return createDisplay(
            width: resolution.width,
            height: resolution.height,
            ppi: resolution.ppi,
            hiDPI: resolution.hiDPI,
            name: resolution.name
        )
    }
    
    /// Creates a virtual display with custom parameters
    func createDisplay(width: Int, height: Int, ppi: Int, hiDPI: Bool, name: String) -> CGDirectDisplayID? {
        // Call the Objective-C function
        guard let display = createVirtualDisplay(
            Int32(width),
            Int32(height),
            Int32(ppi),
            hiDPI,
            name,
            serialNum
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
        LogManager.shared.log("VirtualDisplayManager: Destroyed virtual display")
    }
    
    deinit {
        destroyDisplay()
    }
}
