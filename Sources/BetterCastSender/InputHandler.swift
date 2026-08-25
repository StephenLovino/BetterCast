import Foundation
import CoreGraphics
import Cocoa

class InputHandler {
    static let shared = InputHandler()

    // Per-connection display bounds for multi-display routing
    private var displayBoundsMap: [UUID: CGRect] = [:]

    // Fallback bounds if no connection-specific bounds found
    private var fallbackOrigin: CGPoint = .zero
    private var fallbackWidth: CGFloat = 1920
    private var fallbackHeight: CGFloat = 1080

    func updateDisplayBounds(bounds: CGRect, for connectionId: UUID) {
        displayBoundsMap[connectionId] = bounds
        LogManager.shared.log("InputHandler: Updated bounds for connection \(connectionId.uuidString.prefix(8)): \(bounds)")
    }

    func removeDisplayBounds(for connectionId: UUID) {
        displayBoundsMap.removeValue(forKey: connectionId)
        // A device that disconnects mid-drag would otherwise leave its button latched
        // down, and every later move on that connection would post as a drag.
        releaseButtons(for: connectionId)
    }

    /// Drop any latched button state, and lift a button that is genuinely still down
    /// so the Mac is not left holding a click nobody can release.
    private func releaseButtons(for connectionId: UUID) {
        if leftButtonDown.remove(connectionId) != nil {
            postMouseEvent(type: .leftMouseUp, point: currentCursorPoint(), button: .left)
        }
        if rightButtonDown.remove(connectionId) != nil {
            postMouseEvent(type: .rightMouseUp, point: currentCursorPoint(), button: .right)
        }
        // Leaving a stylus in range after its device has gone keeps apps in a
        // pressure-aware mode with nothing driving it.
        if stylusInProximity.remove(connectionId) != nil {
            postProximity(entering: false)
        }
    }

    private func currentCursorPoint() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    func getDisplayBounds(for connectionId: UUID) -> CGRect {
        return displayBoundsMap[connectionId] ?? .zero
    }

    func removeAllDisplayBounds() {
        for id in displayBoundsMap.keys { releaseButtons(for: id) }
        displayBoundsMap.removeAll()
    }
    
    func checkAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if trusted {
             LogManager.shared.log("InputHandler: Accessibility Permissions Granted. Direct Control Active.")
        } else {
             LogManager.shared.log("InputHandler: Accessibility Permissions MISSING. Mouse control will fail.")
             // macOS will show prompt automatically due to options
        }
    }
    
    private var logThrottle = 0

    func handle(event: InputEvent, for connectionId: UUID) {
        let bounds: CGRect
        let usingFallback: Bool
        if let b = displayBoundsMap[connectionId] {
            bounds = b
            usingFallback = false
        } else {
            bounds = CGRect(origin: fallbackOrigin, size: CGSize(width: fallbackWidth, height: fallbackHeight))
            usingFallback = true
        }

        let x = bounds.origin.x + (CGFloat(event.x) * bounds.width)
        let y = bounds.origin.y + (CGFloat(event.y) * bounds.height)
        let point = CGPoint(x: x, y: y)

        // Log every 60th mouse event to avoid spam
        if event.type == .mouseMove {
            logThrottle += 1
            if logThrottle % 60 == 1 {
                LogManager.shared.log("InputHandler: move → (\(Int(x)),\(Int(y))) bounds=\(bounds) fallback=\(usingFallback) conn=\(connectionId.uuidString.prefix(8))")
            }
        }
        
        // Stylus events take a different route entirely: macOS only reports pressure and
        // tilt to apps when the event carries tablet fields, so a Pencil stroke has to be
        // posted as tablet input rather than as a mouse move that happens to know its
        // pressure. Drawing apps then pick it up with no per-app work.
        if let pressure = event.pressure {
            handleTablet(event: event, point: point, pressure: pressure, connectionId: connectionId)
            return
        }

        switch event.type {
        case .mouseMove:
            // A move with the button held is a DRAG, and macOS will not treat it as one
            // unless it is posted as .leftMouseDragged. Posting .mouseMoved throughout
            // meant text never selected, sliders never followed the finger, and nothing
            // could be dragged across the desktop — the pointer simply travelled while
            // the button sat down. Which button is held decides the event type.
            if leftButtonDown.contains(connectionId) {
                if logThrottle % 60 == 1 {
                    LogManager.shared.log("InputHandler: dragging (button held) → (\(Int(x)),\(Int(y)))")
                }
                postMouseEvent(type: .leftMouseDragged, point: point, button: .left)
            } else if rightButtonDown.contains(connectionId) {
                postMouseEvent(type: .rightMouseDragged, point: point, button: .right)
            } else {
                postMouseEvent(type: .mouseMoved, point: point, button: .left) // Button ignored for move
            }
        case .leftMouseDown:
            LogManager.shared.log("InputHandler: leftDown → (\(Int(x)),\(Int(y))) bounds=\(bounds) fallback=\(usingFallback) clicks=\(event.clickCount ?? 1)")
            leftButtonDown.insert(connectionId)
            postMouseEvent(type: .leftMouseDown, point: point, button: .left, clickCount: event.clickCount ?? 1)
        case .leftMouseUp:
            let wasDown = leftButtonDown.remove(connectionId) != nil
            // Logged as the pair to leftDown: an up that never arrives would latch the
            // button and turn every later move into a drag, which looks from the outside
            // like input dying altogether.
            LogManager.shared.log("InputHandler: leftUp → (\(Int(x)),\(Int(y))) wasDown=\(wasDown)")
            postMouseEvent(type: .leftMouseUp, point: point, button: .left, clickCount: event.clickCount ?? 1)
        case .rightMouseDown:
            LogManager.shared.log("InputHandler: rightDown → (\(Int(x)),\(Int(y))) bounds=\(bounds) fallback=\(usingFallback)")
            rightButtonDown.insert(connectionId)
            postMouseEvent(type: .rightMouseDown, point: point, button: .right, clickCount: event.clickCount ?? 1)
        case .rightMouseUp:
            rightButtonDown.remove(connectionId)
            postMouseEvent(type: .rightMouseUp, point: point, button: .right, clickCount: event.clickCount ?? 1)
        case .keyDown:
            postKeyboardEvent(keyCode: event.keyCode, keyDown: true)
        case .keyUp:
            postKeyboardEvent(keyCode: event.keyCode, keyDown: false)
        case .scrollWheel:
            switch event.keyCode {
            case 1:
                // Pinch-to-zoom: simulate Cmd+scroll (standard zoom gesture for most apps)
                if let scrollEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(event.deltaY), wheel2: 0, wheel3: 0) {
                    scrollEvent.flags = .maskCommand
                    scrollEvent.post(tap: .cghidEventTap)
                }
            case 2:
                // Rotation: simulate as horizontal scroll with Ctrl (app-dependent)
                if let scrollEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: Int32(event.deltaX), wheel3: 0) {
                    scrollEvent.flags = .maskControl
                    scrollEvent.post(tap: .cghidEventTap)
                }
            case 3:
                // Smart zoom: simulate Ctrl+scroll-up as a zoom toggle
                if let scrollEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 5, wheel2: 0, wheel3: 0) {
                    scrollEvent.flags = .maskCommand
                    scrollEvent.post(tap: .cghidEventTap)
                }
            default:
                // Normal two-finger scroll, in whichever direction this Mac scrolls.
                //
                // Synthesized scroll events bypass the flip macOS applies to a real
                // trackpad, so "Natural scrolling" was ignored and two fingers always
                // scrolled the classic way. On a Mac left at the default that is simply
                // backwards, and it is the one gesture that felt unlike the trackpad
                // sitting next to it. The receiver sends classic-oriented deltas, so
                // natural scrolling is the case that needs inverting.
                let direction: Int32 = naturalScrolling ? -1 : 1
                if let scrollEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                             wheel1: direction * Int32(event.deltaY),
                                             wheel2: direction * Int32(event.deltaX),
                                             wheel3: 0) {
                    scrollEvent.post(tap: .cghidEventTap)
                }
            }
        case .command:
            break // Handled by NetworkClient
        }
    }
    
    /// Whether this Mac is set to "Natural scrolling" (System Settings > Trackpad).
    ///
    /// The key only exists once someone has changed it, and the shipping default is on,
    /// so an absent value means natural. Read fresh rather than cached: changing the
    /// setting should take effect on the next gesture, not the next launch.
    private var naturalScrolling: Bool {
        UserDefaults.standard.object(forKey: "com.apple.swipescrolldirection") as? Bool ?? true
    }

    /// Which connections are holding a button down, so a move can be posted as a drag.
    /// Per connection, because several devices drive their own displays at once.
    private var leftButtonDown: Set<UUID> = []
    private var rightButtonDown: Set<UUID> = []

    // MARK: - Stylus

    // A synthetic tablet, deliberately not impersonating a real vendor so it is
    // obvious in logs where these events came from. macOS never looks these up; they
    // exist so apps can tell one pointing device from another.
    private let tabletVendorID: Int64 = 0x0BC0      // "BC"
    private let tabletProductID: Int64 = 0x0001
    private let tabletDeviceID: Int64 = 1
    /// Advertises pressure, tilt and rotation so apps enable their pressure-aware paths.
    private let tabletCapabilityMask: Int64 = 0x05C7

    /// Connections whose stylus macOS currently believes is near the tablet.
    private var stylusInProximity: Set<UUID> = []

    private func handleTablet(event: InputEvent, point: CGPoint, pressure: Double, connectionId: UUID) {
        let goingAway = (event.type == .leftMouseUp)

        // Apps ignore tablet data until the pointer is announced as in range.
        if !goingAway && !stylusInProximity.contains(connectionId) {
            postProximity(entering: true)
            stylusInProximity.insert(connectionId)
        }

        let cgType: CGEventType
        switch event.type {
        case .leftMouseDown:
            leftButtonDown.insert(connectionId)
            cgType = .leftMouseDown
        case .leftMouseUp:
            leftButtonDown.remove(connectionId)
            cgType = .leftMouseUp
        default:
            // Contact with the glass is a drag; hovering above it is a bare move.
            cgType = leftButtonDown.contains(connectionId) ? .leftMouseDragged : .mouseMoved
        }

        guard let ev = CGEvent(mouseEventSource: nil, mouseType: cgType,
                               mouseCursorPosition: point, mouseButton: .left) else { return }

        // Tilt is the pencil's lean flattened onto the screen's axes. Upright means no
        // lean on either axis, so cos(altitude) scales it and azimuth points it.
        let altitude = event.altitude ?? (.pi / 2)
        let azimuth = event.azimuth ?? 0
        let lean = cos(altitude)

        ev.setIntegerValueField(.mouseEventSubtype, value: Int64(CGEventMouseSubtype.tabletPoint.rawValue))
        ev.setDoubleValueField(.tabletEventPointPressure, value: pressure)
        ev.setDoubleValueField(.tabletEventTiltX, value: cos(azimuth) * lean)
        ev.setDoubleValueField(.tabletEventTiltY, value: sin(azimuth) * lean)
        ev.setIntegerValueField(.tabletEventDeviceID, value: tabletDeviceID)
        ev.post(tap: .cghidEventTap)

        if goingAway {
            postProximity(entering: false)
            stylusInProximity.remove(connectionId)
        }
    }

    /// Tell macOS the stylus has come into or gone out of range.
    private func postProximity(entering: Bool) {
        guard let ev = CGEvent(source: nil) else { return }
        ev.type = .tabletProximity
        ev.setIntegerValueField(.tabletProximityEventVendorID, value: tabletVendorID)
        ev.setIntegerValueField(.tabletProximityEventTabletID, value: tabletProductID)
        ev.setIntegerValueField(.tabletProximityEventDeviceID, value: tabletDeviceID)
        ev.setIntegerValueField(.tabletProximityEventSystemTabletID, value: 0)
        ev.setIntegerValueField(.tabletProximityEventPointerType,
                                value: Int64(NX_TABLET_POINTER_PEN))
        ev.setIntegerValueField(.tabletProximityEventCapabilityMask, value: tabletCapabilityMask)
        ev.setIntegerValueField(.tabletProximityEventEnterProximity, value: entering ? 1 : 0)
        ev.post(tap: .cghidEventTap)
    }

    private func postMouseEvent(type: CGEventType, point: CGPoint, button: CGMouseButton, clickCount: Int = 1) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return }
        if clickCount > 1 {
            event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        }
        event.post(tap: .cghidEventTap)
    }
    
    private func postKeyboardEvent(keyCode: UInt16, keyDown: Bool) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: keyDown) else { return }
        event.post(tap: .cghidEventTap)
    }

    /// Post a single Ctrl+Arrow keyboard chord for trackpad-style desktop gestures
    /// (Mission Control / App Exposé / switch space). keyCode is the BetterCast
    /// command code (600..603), not the raw macOS virtual key.
    func postTrackpadShortcut(keyCode: UInt16) {
        let virtualKey: CGKeyCode
        let label: String
        switch keyCode {
        case 600: virtualKey = 0x7E; label = "Mission Control (Ctrl+Up)"
        case 601: virtualKey = 0x7D; label = "App Exposé (Ctrl+Down)"
        case 602: virtualKey = 0x7B; label = "Switch space left (Ctrl+Left)"
        case 603: virtualKey = 0x7C; label = "Switch space right (Ctrl+Right)"
        default: return
        }
        LogManager.shared.log("InputHandler: trackpad shortcut → \(label)")
        if let down = CGEvent(keyboardEventSource: nil, virtualKey: virtualKey, keyDown: true) {
            down.flags = .maskControl
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: nil, virtualKey: virtualKey, keyDown: false) {
            up.flags = .maskControl
            up.post(tap: .cghidEventTap)
        }
    }
}
