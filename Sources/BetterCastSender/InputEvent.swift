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
    case command = 99 // Internal commands (e.g. Force Keyframe)
}

struct InputEvent: Codable {
    let type: InputEventType
    let x: Double // Normalized 0-1
    let y: Double // Normalized 0-1
    let keyCode: UInt16
    let deltaX: Double
    let deltaY: Double
    let eventId: UInt64 // Unique ID for deduplication of redundant UDP sends

    private static var nextId: UInt64 = 0

    init(type: InputEventType, x: Double = 0, y: Double = 0, keyCode: UInt16 = 0, deltaX: Double = 0, deltaY: Double = 0, eventId: UInt64? = nil) {
        self.type = type
        self.x = x
        self.y = y
        self.keyCode = keyCode
        self.deltaX = deltaX
        self.deltaY = deltaY
        if let id = eventId {
            self.eventId = id
        } else {
            InputEvent.nextId += 1
            self.eventId = InputEvent.nextId
        }
    }
}
