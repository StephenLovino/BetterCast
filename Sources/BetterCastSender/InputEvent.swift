import Foundation

enum InputEventType: Int, Codable {
    case mouseMove = 0
    case leftMouseDown = 1
    case leftMouseUp = 2
    case rightMouseDown = 3
    case rightMouseUp = 4
    case keyDown = 5
    case keyUp = 6
    case scrollWheel = 7
}

struct InputEvent: Codable {
    let type: InputEventType
    let x: Double // Normalized 0-1
    let y: Double // Normalized 0-1
    let keyCode: UInt16
    let deltaX: Double
    let deltaY: Double
}
