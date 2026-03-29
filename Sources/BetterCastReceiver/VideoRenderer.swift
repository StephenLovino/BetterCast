import SwiftUI
import AVFoundation
import CoreMedia

struct VideoRendererView: NSViewRepresentable {
    let renderer: VideoRenderer
    
    func makeNSView(context: Context) -> NSView {
        return renderer.view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        renderer.layout()
    }
}

class InputOverlayView: NSView {
    var onInput: ((InputEvent) -> Void)?
    
    override var acceptsFirstResponder: Bool { true }
    
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .enabledDuringMouseDrag], owner: self, userInfo: nil))
    }
    
    private func normalize(point: NSPoint) -> (Double, Double)? {
        // Calculate the actual video frame rect to handle letterboxing correctly
        let viewSize = bounds.size
        if viewSize.width == 0 || viewSize.height == 0 || contentSize.width == 0 || contentSize.height == 0 { return nil }
        
        let widthRatio = viewSize.width / contentSize.width
        let heightRatio = viewSize.height / contentSize.height
        let scale = min(widthRatio, heightRatio)
        
        let videoWidth = contentSize.width * scale
        let videoHeight = contentSize.height * scale
        
        let xOffset = (viewSize.width - videoWidth) / 2.0
        let yOffset = (viewSize.height - videoHeight) / 2.0
        
        // NSView coords: 0,0 is bottom-left. Video is centered.
        // Convert point to video-relative coords.
        let relX = point.x - xOffset
        let relY = point.y - yOffset
        
        if relX < 0 || relX > videoWidth || relY < 0 || relY > videoHeight {
            return nil // Clicked in black bars
        }
        
        // Normalize 0-1
        let normX = Double(relX / videoWidth)
        // Invert Y for Top-Left origin (Sender expects 0 at Top)
        // NSView Y increases upwards. relY increases upwards.
        // We want 0 at Top of video.
        // At Top of video (relY = videoHeight), we want 0.0.
        // At Bottom of video (relY = 0), we want 1.0.
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
        // Two-finger scroll on trackpad or mouse scroll wheel
        // Use scrollingDeltaX/Y for smooth trackpad scrolling
        let dx: Double
        let dy: Double
        if event.hasPreciseScrollingDeltas {
            // Trackpad: precise pixel deltas
            dx = Double(event.scrollingDeltaX)
            dy = Double(event.scrollingDeltaY)
        } else {
            // Mouse wheel: line-based deltas, scale up for usable movement
            dx = Double(event.scrollingDeltaX) * 10.0
            dy = Double(event.scrollingDeltaY) * 10.0
        }
        if dx != 0 || dy != 0 {
            onInput?(InputEvent(type: .scrollWheel, deltaX: dx, deltaY: dy))
        }
    }

    override func magnify(with event: NSEvent) {
        // Pinch-to-zoom: send as scroll with a modifier flag via keyCode
        // keyCode 1 signals magnification gesture to the sender
        let magnitude = Double(event.magnification) * 100.0
        onInput?(InputEvent(type: .scrollWheel, keyCode: 1, deltaY: magnitude))
    }

    override func rotate(with event: NSEvent) {
        // Two-finger rotation: send as scroll with keyCode 2
        let rotation = Double(event.rotation)
        onInput?(InputEvent(type: .scrollWheel, keyCode: 2, deltaX: rotation))
    }

    override func smartMagnify(with event: NSEvent) {
        // Double-tap with two fingers (smart zoom toggle)
        // Send as scroll with keyCode 3
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
        // Ensure sublayers (video layer) fill the view
        if let sublayers = layer?.sublayers {
            for sublayer in sublayers {
                sublayer.frame = bounds
            }
        }
    }
}

class VideoRenderer: ObservableObject {
    let view = InputOverlayView()
    private let displayLayer = AVSampleBufferDisplayLayer()
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
        
        // Critical: Set timebase to run immediately
        var timebase: CMTimebase?
        CMTimebaseCreateWithMasterClock(allocator: kCFAllocatorDefault, masterClock: CMClockGetHostTimeClock(), timebaseOut: &timebase)
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
        if displayLayer.status == .failed {
            LogManager.shared.log("VideoRenderer: Layer failed \(String(describing: displayLayer.error)). Re-creating...")
            displayLayer.flush()
        }
        
        // Update Aspect Ratio from Sample Buffer (Only if changed)
        if let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            let dim = CMVideoFormatDescriptionGetDimensions(format)
            let width = CGFloat(dim.width)
            let height = CGFloat(dim.height)
            
            // Direct update (we are already on Main Thread via didDecode)
            let newSize = CGSize(width: width, height: height)
            if width > 0 && height > 0 && view.contentSize != newSize {
                 view.contentSize = newSize
                 videoSize = newSize
            }
        }
        
        // Force immediate display attachment
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) as? [[CFString: Any]]
        if let _ = attachments {
             let dict = CFArrayGetValueAtIndex(CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true), 0)
             let dictRef = unsafeBitCast(dict, to: CFMutableDictionary.self)
             CFDictionarySetValue(dictRef, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        
        // Enqueue efficiently
        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        
        displayLayer.enqueue(sampleBuffer)
    }
}
