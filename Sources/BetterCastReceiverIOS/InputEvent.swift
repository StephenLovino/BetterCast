#if canImport(UIKit)
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
    /// Optional friendly device name, set by command keyCode=770 (device hello).
    /// Lets the Mac sender re-dial via the proper Bonjour service name instead of
    /// labelling the connection "iOS @ <ip>:<port>".
    let deviceName: String?

    /// 1 for a single click, 2 for a double, 3 for a triple. macOS only reports a
    /// double-click to apps when the event carries the click state, so this has to
    /// travel with the click rather than being inferred from timing on the Mac.
    let clickCount: Int?

    /// Apple Pencil pressure 0-1, plus how the pencil is being held. Sent only for
    /// stylus touches; their absence is what tells the Mac this was a finger.
    let pressure: Double?
    /// Angle between pencil and screen in radians. π/2 is upright.
    let altitude: Double?
    /// Compass direction the pencil points, in radians.
    let azimuth: Double?

    private static var nextId: UInt64 = 0

    init(type: InputEventType, x: Double = 0, y: Double = 0, keyCode: UInt16 = 0, deltaX: Double = 0, deltaY: Double = 0, deviceName: String? = nil, clickCount: Int? = nil, pressure: Double? = nil, altitude: Double? = nil, azimuth: Double? = nil) {
        self.clickCount = clickCount
        self.pressure = pressure
        self.altitude = altitude
        self.azimuth = azimuth
        self.type = type
        self.x = x
        self.y = y
        self.keyCode = keyCode
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.deviceName = deviceName
        InputEvent.nextId += 1
        self.eventId = InputEvent.nextId
    }
}
#endif

