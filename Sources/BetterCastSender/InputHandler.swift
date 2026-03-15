import Foundation
import CoreGraphics
import Cocoa

class InputHandler {
    static let shared = InputHandler()
    
    // Screen resolution management
    var displayOrigin: CGPoint = .zero
    var displayWidth: CGFloat = 1920
    var displayHeight: CGFloat = 1080
    
    func updateDisplayBounds(bounds: CGRect) {
        self.displayOrigin = bounds.origin
        self.displayWidth = bounds.width
        self.displayHeight = bounds.height
        // LogManager.shared.log("InputHandler: Updated bounds to \(bounds)")
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
    
    func handle(event: InputEvent) {
        let x = displayOrigin.x + (CGFloat(event.x) * displayWidth)
        let y = displayOrigin.y + (CGFloat(event.y) * displayHeight)
        let point = CGPoint(x: x, y: y)
        
        switch event.type {
        case .mouseMove:
            postMouseEvent(type: .mouseMoved, point: point, button: .left) // Button ignored for move
        case .leftMouseDown:
            postMouseEvent(type: .leftMouseDown, point: point, button: .left)
        case .leftMouseUp:
            postMouseEvent(type: .leftMouseUp, point: point, button: .left)
        case .rightMouseDown:
            postMouseEvent(type: .rightMouseDown, point: point, button: .right)
        case .rightMouseUp:
            postMouseEvent(type: .rightMouseUp, point: point, button: .right)
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
                // Normal two-finger scroll
                if let scrollEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(event.deltaY), wheel2: Int32(event.deltaX), wheel3: 0) {
                    scrollEvent.post(tap: .cghidEventTap)
                }
            }
        case .command:
            break // Handled by NetworkClient
        }
    }
    
    private func postMouseEvent(type: CGEventType, point: CGPoint, button: CGMouseButton) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return }
        event.post(tap: .cghidEventTap)
    }
    
    private func postKeyboardEvent(keyCode: UInt16, keyDown: Bool) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: keyDown) else { return }
        event.post(tap: .cghidEventTap)
    }
}
