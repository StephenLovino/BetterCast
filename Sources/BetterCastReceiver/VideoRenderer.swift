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
    
    private func normalize(point: NSPoint) -> (Double, Double) {
        return (Double(point.x / bounds.width), Double(1.0 - (point.y / bounds.height))) // CGEvent coords are top-left origin? Wait, NSView is bottom-left. CGEvent is top-left.
        // We need to send normalized coordinates (0,0 top-left, 1,1 bottom-right) usually for standard protocols.
        // NSView: (0,0) is bottom-left.
        // Screen: (0,0) is top-left (usually).
        // Let's invert Y.
    }
    
    override func mouseMoved(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        let (nx, ny) = normalize(point: loc)
        onInput?(InputEvent(type: .mouseMove, x: nx, y: ny))
    }
    
    override func mouseDragged(with event: NSEvent) {
        // Handle drag as move for now
        mouseMoved(with: event)
    }
    
    override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        let (nx, ny) = normalize(point: loc)
        onInput?(InputEvent(type: .leftMouseDown, x: nx, y: ny))
    }
    
    override func mouseUp(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        let (nx, ny) = normalize(point: loc)
        onInput?(InputEvent(type: .leftMouseUp, x: nx, y: ny))
    }
    
    override func rightMouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        let (nx, ny) = normalize(point: loc)
        onInput?(InputEvent(type: .rightMouseDown, x: nx, y: ny))
    }
    
    override func rightMouseUp(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        let (nx, ny) = normalize(point: loc)
        onInput?(InputEvent(type: .rightMouseUp, x: nx, y: ny))
    }
    
    override func keyDown(with event: NSEvent) {
        onInput?(InputEvent(type: .keyDown, keyCode: event.keyCode))
    }
    
    override func keyUp(with event: NSEvent) {
        onInput?(InputEvent(type: .keyUp, keyCode: event.keyCode))
    }
    
    override func scrollWheel(with event: NSEvent) {
        onInput?(InputEvent(type: .scrollWheel, deltaX: Double(event.scrollingDeltaX), deltaY: Double(event.scrollingDeltaY)))
    }
}

class VideoRenderer: ObservableObject {
    let view = InputOverlayView()
    private let displayLayer = AVSampleBufferDisplayLayer()
    
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
            CMTimebaseSetTime(timebase, time: CMTime.zero)
            CMTimebaseSetRate(timebase, rate: 1.0)
        }
        
        view.layer?.addSublayer(displayLayer)
    }
    
    func layout() {
        displayLayer.frame = view.bounds
    }
    
    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        if displayLayer.status == .failed {
            LogManager.shared.log("VideoRenderer: Layer failed \(String(describing: displayLayer.error)). Re-creating...")
            displayLayer.flush()
        }
        
        // Force immediate display attachment again just to be safe
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) as? [[CFString: Any]]
        if let _ = attachments {
             let dict = CFArrayGetValueAtIndex(CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true), 0)
             let dictRef = unsafeBitCast(dict, to: CFMutableDictionary.self)
             CFDictionarySetValue(dictRef, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        
        if displayLayer.isReadyForMoreMediaData {
            displayLayer.enqueue(sampleBuffer)
        } else {
             displayLayer.enqueue(sampleBuffer)
        }
    }
}
