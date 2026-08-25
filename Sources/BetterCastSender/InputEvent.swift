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
    /// Friendly device name carried alongside command keyCode=770 (device hello),
    /// sent by receivers that dialed in via the invite path so the sender can
    /// re-dial them via the proper Bonjour service name + AWDL routing.
    let deviceName: String?

    /// 1 for a single click, 2 for a double, 3 for a triple.
    ///
    /// macOS does not infer this from two clicks arriving close together: an app only
    /// sees a double-click if the event carries the click state. Without it a
    /// double-tap on the device opened nothing, selected no word, expanded no folder.
    /// Absent on receivers that predate this, which is read as 1.
    let clickCount: Int?

    /// Stylus pressure, 0-1. Present only when the event came from an Apple Pencil.
    ///
    /// Its presence is what marks an event as stylus rather than finger: a receiver
    /// that predates pencil support simply omits it, and the Mac posts ordinary mouse
    /// events as before. A Pencil talking to an older Mac therefore still draws, just
    /// at a constant width.
    let pressure: Double?
    /// Angle between the pencil and the screen, in radians. π/2 is upright.
    let altitude: Double?
    /// Compass direction the pencil points, in radians.
    let azimuth: Double?

    private static var nextId: UInt64 = 0

    init(type: InputEventType, x: Double = 0, y: Double = 0, keyCode: UInt16 = 0, deltaX: Double = 0, deltaY: Double = 0, eventId: UInt64? = nil, deviceName: String? = nil, clickCount: Int? = nil, pressure: Double? = nil, altitude: Double? = nil, azimuth: Double? = nil) {
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
        if let id = eventId {
            self.eventId = id
        } else {
            InputEvent.nextId += 1
            self.eventId = InputEvent.nextId
        }
    }
}
