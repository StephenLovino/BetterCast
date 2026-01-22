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
        Resolution(width: 1920, height: 1080, ppi: 102, hiDPI: false, name: "1080p (16:9)"),
        Resolution(width: 1920, height: 1200, ppi: 113, hiDPI: false, name: "1200p (16:10)"),
        Resolution(width: 2560, height: 1440, ppi: 109, hiDPI: false, name: "1440p (16:9)"),
        Resolution(width: 2560, height: 1600, ppi: 227, hiDPI: true, name: "1600p Retina (16:10)"),
        Resolution(width: 3840, height: 2160, ppi: 163, hiDPI: false, name: "4K (16:9)"),
        Resolution(width: 1440, height: 900, ppi: 127, hiDPI: false, name: "WXGA+ (16:10)"),
    ]
    
    private var activeDisplay: Any?
    private(set) var displayID: CGDirectDisplayID?
    
    init() {}
    
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
            name
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
