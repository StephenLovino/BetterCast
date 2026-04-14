import SwiftUI
import AVFoundation
import CoreMedia

struct ReceiverVideoRendererView: NSViewRepresentable {
    let renderer: ReceiverVideoRenderer

    func makeNSView(context: Context) -> NSView {
        return renderer.view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        renderer.layout()
    }
}

class ReceiverInputOverlayView: NSView {
    var onInput: ((InputEvent) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .enabledDuringMouseDrag], owner: self, userInfo: nil))
    }

    private func normalize(point: NSPoint) -> (Double, Double)? {
        let viewSize = bounds.size
        if viewSize.width == 0 || viewSize.height == 0 || contentSize.width == 0 || contentSize.height == 0 { return nil }

        let widthRatio = viewSize.width / contentSize.width
        let heightRatio = viewSize.height / contentSize.height
        let scale = min(widthRatio, heightRatio)

        let videoWidth = contentSize.width * scale
        let videoHeight = contentSize.height * scale

        let xOffset = (viewSize.width - videoWidth) / 2.0
        let yOffset = (viewSize.height - videoHeight) / 2.0

        let relX = point.x - xOffset
        let relY = point.y - yOffset

        if relX < 0 || relX > videoWidth || relY < 0 || relY > videoHeight {
            return nil
        }

        let normX = Double(relX / videoWidth)
        let normY = Double(1.0 - (relY / videoHeight))

        return (normX, normY)
    }

    var contentSize: CGSize = CGSize(width: 1920, height: 1080)

    override func mouseMoved(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        if let (nx, ny) = normalize(point: loc) {
            onInput?(InputEvent(type: .mouseMove, x: nx, y: ny))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        if let (nx, ny) = normalize(point: loc) {
            onInput?(InputEvent(type: .leftMouseDown, x: nx, y: ny))
        }
    }

    override func mouseUp(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        if let (nx, ny) = normalize(point: loc) {
            onInput?(InputEvent(type: .leftMouseUp, x: nx, y: ny))
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        if let (nx, ny) = normalize(point: loc) {
            onInput?(InputEvent(type: .rightMouseDown, x: nx, y: ny))
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        if let (nx, ny) = normalize(point: loc) {
            onInput?(InputEvent(type: .rightMouseUp, x: nx, y: ny))
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let dx: Double
        let dy: Double
        if event.hasPreciseScrollingDeltas {
            dx = Double(event.scrollingDeltaX)
            dy = Double(event.scrollingDeltaY)
        } else {
            dx = Double(event.scrollingDeltaX) * 10.0
            dy = Double(event.scrollingDeltaY) * 10.0
        }
        if dx != 0 || dy != 0 {
            onInput?(InputEvent(type: .scrollWheel, deltaX: dx, deltaY: dy))
        }
    }

    override func magnify(with event: NSEvent) {
        let magnitude = Double(event.magnification) * 100.0
        onInput?(InputEvent(type: .scrollWheel, keyCode: 1, deltaY: magnitude))
    }

    override func rotate(with event: NSEvent) {
        let rotation = Double(event.rotation)
        onInput?(InputEvent(type: .scrollWheel, keyCode: 2, deltaX: rotation))
    }

    override func smartMagnify(with event: NSEvent) {
        onInput?(InputEvent(type: .scrollWheel, keyCode: 3))
    }

    override func keyDown(with event: NSEvent) {
        onInput?(InputEvent(type: .keyDown, keyCode: event.keyCode))
    }

    override func keyUp(with event: NSEvent) {
        onInput?(InputEvent(type: .keyUp, keyCode: event.keyCode))
    }

    override func makeBackingLayer() -> CALayer {
        return CALayer()
    }

    override func layout() {
        super.layout()
        if let sublayers = layer?.sublayers {
            for sublayer in sublayers {
                sublayer.frame = bounds
            }
        }
    }
}

class ReceiverVideoRenderer: ObservableObject {
    let view = ReceiverInputOverlayView()
    private var displayLayer = AVSampleBufferDisplayLayer()
    @Published var videoSize: CGSize = .zero

    var onInput: ((InputEvent) -> Void)? {
        didSet {
            view.onInput = onInput
        }
    }

    init() {
        view.wantsLayer = true
        view.layer = CALayer()
        view.layer?.backgroundColor = NSColor.black.cgColor

        displayLayer.videoGravity = .resizeAspect

        var timebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase)
        if let timebase = timebase {
            displayLayer.controlTimebase = timebase
            CMTimebaseSetRate(timebase, rate: 1.0)
        }

        view.layer?.addSublayer(displayLayer)
    }

    func layout() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = view.bounds
        CATransaction.commit()
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        // Recover from failed state — try flush first, rebuild layer if still stuck
        if displayLayer.status == .failed {
            LogManager.shared.log("ReceiverVideoRenderer: Display layer failed, recovering...")
            rebuildDisplayLayer()
        }

        if let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            let dim = CMVideoFormatDescriptionGetDimensions(format)
            let width = CGFloat(dim.width)
            let height = CGFloat(dim.height)

            let newSize = CGSize(width: width, height: height)
            if width > 0 && height > 0 && view.contentSize != newSize {
                view.contentSize = newSize
                videoSize = newSize
            }
        }

        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) as? [[CFString: Any]]
        if let _ = attachments {
            let dict = CFArrayGetValueAtIndex(CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true), 0)
            let dictRef = unsafeBitCast(dict, to: CFMutableDictionary.self)
            CFDictionarySetValue(dictRef, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        displayLayer.enqueue(sampleBuffer)
    }

    /// Flush the display layer in preparation for a format/dimension change.
    func flushForFormatChange() {
        displayLayer.flush()
    }

    /// Rebuild the display layer from scratch when flush alone cannot recover it.
    private func rebuildDisplayLayer() {
        displayLayer.flush()
        displayLayer.removeFromSuperlayer()

        let newLayer = AVSampleBufferDisplayLayer()
        newLayer.videoGravity = .resizeAspect

        var timebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase)
        if let timebase = timebase {
            newLayer.controlTimebase = timebase
            CMTimebaseSetRate(timebase, rate: 1.0)
        }

        newLayer.frame = view.bounds
        view.layer?.addSublayer(newLayer)
        displayLayer = newLayer
        LogManager.shared.log("ReceiverVideoRenderer: Display layer rebuilt")
    }

    func flush() {
        displayLayer.flush()
        DispatchQueue.main.async {
            self.videoSize = .zero
        }
    }
}
