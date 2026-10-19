import Foundation
import CoreGraphics

// Fitting the virtual display to the receiver's actual screen: custom sizes for screens
// none of the presets match, a remembered native size for devices that cannot report
// one, text size as HiDPI scaled modes, and keeping the display on the side of the main
// screen the user arranged it on.

/// A width and height in whole pixels (or points, where noted).
struct PixelSize: Hashable, Codable {
    var width: Int
    var height: Int

    /// Smallest and largest side accepted for a size the user types in. Below the floor
    /// macOS refuses the mode; the ceiling matches the 5K preset, the largest size the
    /// encoders are already known to handle.
    static let acceptedSides = 640...5120

    /// Rounded down to even sides: H.264 and HEVC both reject odd frame sizes.
    var even: PixelSize { PixelSize(width: width & ~1, height: height & ~1) }
    var rotated: PixelSize { PixelSize(width: height, height: width) }
    var isPortrait: Bool { height > width }
    var label: String { "\(width) x \(height)" }

    /// Parses user input like "2160" and "1584" into an accepted, even size.
    static func parse(width: String, height: String) -> PixelSize? {
        guard let w = Int(width.trimmingCharacters(in: .whitespaces)),
              let h = Int(height.trimmingCharacters(in: .whitespaces)),
              acceptedSides.contains(w), acceptedSides.contains(h) else { return nil }
        return PixelSize(width: w, height: h).even
    }
}

// MARK: - Text size

/// One "looks like" size for a display streaming at a fixed pixel size.
///
/// `pixelsPerPoint` is how many streamed pixels make up one point of UI: 2 is the usual
/// Retina look, higher is larger text, lower fits more on screen. Whatever is picked, the
/// stream stays at the native pixel size; only the UI scale changes.
struct TextSizeOption: Hashable {
    let pixelsPerPoint: Double
    let points: PixelSize
}

enum TextSizing {
    static let defaultPixelsPerPoint = 2.0

    private static let candidates: [Double] = [3.0, 2.5, 2.0, 1.75, 1.5, 1.25, 1.0]

    /// A HiDPI mode is backed by 2x2 pixels per point, so "More Space" on a large panel
    /// needs a framebuffer far bigger than the panel. Leave out modes past 8K per side.
    private static let maxFramebufferSide = 7680

    /// Below this many points on the short side the desktop stops being usable.
    private static let minShortSidePoints = 400

    static func points(native: PixelSize, pixelsPerPoint: Double) -> PixelSize {
        PixelSize(width: Int((Double(native.width) / pixelsPerPoint).rounded()),
                  height: Int((Double(native.height) / pixelsPerPoint).rounded())).even
    }

    /// The sizes offered for `native`, largest text first.
    static func options(native: PixelSize) -> [TextSizeOption] {
        var seen = Set<PixelSize>()
        return candidates.compactMap { ratio in
            let pts = points(native: native, pixelsPerPoint: ratio)
            guard min(pts.width, pts.height) >= minShortSidePoints,
                  max(pts.width, pts.height) * 2 <= maxFramebufferSide,
                  seen.insert(pts).inserted else { return nil }
            return TextSizeOption(pixelsPerPoint: ratio, points: pts)
        }
    }

    /// The option closest to `pixelsPerPoint`, so a saved choice survives a device whose
    /// list is shorter (a smaller panel drops the largest sizes).
    static func nearest(_ pixelsPerPoint: Double, in options: [TextSizeOption]) -> TextSizeOption? {
        options.min { abs($0.pixelsPerPoint - pixelsPerPoint) < abs($1.pixelsPerPoint - pixelsPerPoint) }
    }
}

// MARK: - Per-device screen preferences

/// What the user told us about one device's screen, keyed by device name.
struct DeviceScreenPrefs: Codable, Equatable {
    /// Native panel size, for receivers that do not report their own (command 777).
    var registeredNative: PixelSize?
    /// Chosen text size, as pixels per point. nil = the default Retina look.
    var pixelsPerPoint: Double?
}

final class DeviceScreenPrefsStore {
    private static let defaultsKey = "setting.deviceScreens"
    private var prefs: [String: DeviceScreenPrefs]

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: DeviceScreenPrefs].self, from: data) {
            prefs = decoded
        } else {
            prefs = [:]
        }
    }

    subscript(device: String) -> DeviceScreenPrefs {
        get { prefs[device] ?? DeviceScreenPrefs() }
        set {
            prefs[device] = newValue == DeviceScreenPrefs() ? nil : newValue
            if let data = try? JSONEncoder().encode(prefs) {
                UserDefaults.standard.set(data, forKey: Self.defaultsKey)
            }
        }
    }
}

// MARK: - Placement

/// Which side of the main screen a display sits on, and where along that edge.
///
/// macOS places a display it has not seen at this size before wherever it likes, so a
/// rotated or rescaled display used to reappear on the far side of the main screen.
/// Remembering the side (rather than an absolute origin, which stops making sense once
/// the size changes) lets us put it back next to the same edge.
struct DisplayPlacement: Codable, Equatable {
    enum Side: String, Codable { case right, left, above, below }
    let side: Side
    /// Offset along the shared edge: y for left/right, x for above/below.
    let along: Double

    init?(bounds: CGRect, main: CGRect) {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        if bounds.minX >= main.maxX - 1 {
            side = .right; along = bounds.minY
        } else if bounds.maxX <= main.minX + 1 {
            side = .left; along = bounds.minY
        } else if bounds.maxY <= main.minY + 1 {
            side = .above; along = bounds.minX
        } else if bounds.minY >= main.maxY - 1 {
            side = .below; along = bounds.minX
        } else {
            return nil  // overlapping the main screen: mirrored, or mid-rearrange
        }
    }

    /// The origin that puts a display of `size` back against the same edge.
    func origin(for size: CGSize, main: CGRect) -> CGPoint {
        switch side {
        case .right: return CGPoint(x: main.maxX, y: along)
        case .left:  return CGPoint(x: main.minX - size.width, y: along)
        case .above: return CGPoint(x: along, y: main.minY - size.height)
        case .below: return CGPoint(x: along, y: main.maxY)
        }
    }
}

final class DisplayPlacementStore {
    private static let defaultsKey = "setting.displayPlacements"
    private var placements: [String: DisplayPlacement]

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: DisplayPlacement].self, from: data) {
            placements = decoded
        } else {
            placements = [:]
        }
    }

    func remember(_ bounds: CGRect, for device: String) {
        guard let placement = DisplayPlacement(bounds: bounds, main: CGDisplayBounds(CGMainDisplayID())),
              placements[device] != placement else { return }
        placements[device] = placement
        if let data = try? JSONEncoder().encode(placements) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    /// Moves `displayID` back to the side recorded for `device`, if it has drifted.
    func restore(_ displayID: CGDirectDisplayID, for device: String) {
        guard displayID != CGMainDisplayID(), let placement = placements[device] else { return }
        let current = CGDisplayBounds(displayID)
        let main = CGDisplayBounds(CGMainDisplayID())
        guard current.width > 0 else { return }
        if DisplayPlacement(bounds: current, main: main)?.side == placement.side { return }

        let target = placement.origin(for: current.size, main: main)
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }
        CGConfigureDisplayOrigin(config, displayID, Int32(target.x.rounded()), Int32(target.y.rounded()))
        // Session scope only: the arrangement macOS saves for this display is the user's.
        let err = CGCompleteDisplayConfiguration(config, .forSession)
        LogManager.shared.log("Sender: Moved \(device) display back to the \(placement.side.rawValue) of the main screen: \(err == .success ? "ok" : "error \(err.rawValue)")")
    }
}

// MARK: - Display modes

extension VirtualDisplayManager {
    /// The size the display currently looks like, in points.
    var currentPointSize: PixelSize? {
        guard let id = displayID, let mode = CGDisplayCopyDisplayMode(id) else { return nil }
        return PixelSize(width: mode.width, height: mode.height)
    }

    /// Switches the live display to its HiDPI mode of `points`. No rebuild, so the
    /// stream and the windows on the display carry on.
    @discardableResult
    func switchMode(toPoints points: PixelSize) -> Bool {
        guard let id = displayID else { return false }
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []
        let match = modes
            .filter { $0.width == points.width && $0.height == points.height }
            .max { $0.pixelWidth < $1.pixelWidth }
        guard let match else {
            LogManager.shared.log("VirtualDisplayManager: display \(id) has no \(points.label) mode")
            return false
        }
        let err = CGDisplaySetDisplayMode(id, match, nil)
        LogManager.shared.log("VirtualDisplayManager: display \(id) -> \(points.label) pt: \(err == .success ? "ok" : "error \(err.rawValue)")")
        return err == .success
    }
}

extension VirtualDisplayManager.Resolution {
    /// A user-typed size for screens the presets do not cover (foldables, 3:2, 4:3).
    static func custom(_ size: PixelSize) -> Self {
        let clamped = PixelSize(
            width: min(max(size.width, PixelSize.acceptedSides.lowerBound), PixelSize.acceptedSides.upperBound),
            height: min(max(size.height, PixelSize.acceptedSides.lowerBound), PixelSize.acceptedSides.upperBound)
        ).even
        return Self(width: clamped.width, height: clamped.height, ppi: 110, hiDPI: false,
                    name: "\(clamped.label) (\(tr("Custom")))")
    }

    var isPreset: Bool {
        VirtualDisplayManager.defaultResolutions.contains { $0.width == width && $0.height == height }
    }
}
