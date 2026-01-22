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
            // Scroll wheel is complex in CGEvent, simplified here
            if let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(event.deltaY), wheel2: Int32(event.deltaX), wheel3: 0) {
                 event.post(tap: .cghidEventTap)
            }
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
