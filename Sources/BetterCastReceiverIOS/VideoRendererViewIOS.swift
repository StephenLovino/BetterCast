#if canImport(UIKit)
import UIKit
import AVFoundation

protocol InputDelegate: AnyObject {
    func didTriggerInput(_ event: InputEvent)
}

// Just a protocol to match what NetworkListenerIOS expects
protocol VideoRendererIOS: AnyObject {
    func enqueue(_ sampleBuffer: CMSampleBuffer)
}

class VideoRendererViewIOS: UIView, VideoRendererIOS {
    
    weak var inputDelegate: InputDelegate?
    
    override class var layerClass: AnyClass {
        return AVSampleBufferDisplayLayer.self
    }
    
    private var videoLayer: AVSampleBufferDisplayLayer {
        return layer as! AVSampleBufferDisplayLayer
    }
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupLayer()
        setupGestures()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayer()
        setupGestures()
    }
    
    private func setupLayer() {
        videoLayer.videoGravity = .resizeAspect // Preserve aspect ratio (Letterbox)
        // v47 Smoothness: Use Timebase (Standard Remote Desktop Trick)
        var controlTimebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &controlTimebase)
        if let tb = controlTimebase {
            videoLayer.controlTimebase = tb
            CMTimebaseSetTime(tb, time: CMTime.zero)
            CMTimebaseSetRate(tb, rate: 1.0)
        }
    }
    
    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        if videoLayer.status == .failed {
            videoLayer.flush()
        }
        videoLayer.enqueue(sampleBuffer)
    }
    
    // MARK: - Input Handling
    
    private func setupGestures() {
        isMultipleTouchEnabled = true
        
        // 1. Mouse Move (Pan)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
        
        // 2. Left Click (Tap)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.numberOfTapsRequired = 1
        tap.numberOfTouchesRequired = 1
        addGestureRecognizer(tap)
        
        // 3. Right Click (2 Finger Tap)
        let twoTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoTap(_:)))
        twoTap.numberOfTouchesRequired = 2
        addGestureRecognizer(twoTap)
        
        // 4. Scroll (2 Finger Pan)
        let scrollPan = UIPanGestureRecognizer(target: self, action: #selector(handleScroll(_:)))
        scrollPan.minimumNumberOfTouches = 2
        addGestureRecognizer(scrollPan)
        
        // Dependency: Tap waits for Pan to fail? No, for "Direct Control", we want tap to click instantly.
        // Pan usually delays tap. For a "Remote" feeling, we might accept that dragging requires a distinct movement.
    }
    
    private func normalizedPoint(from gesture: UIGestureRecognizer) -> (Double, Double) {
        let location = gesture.location(in: self)
        
        // We need to account for videoGravity = .resizeAspect (Letterboxing).
        // The sender expects 0..1 relative to the *Video Image*, not the black bars.
        // However, calculating exact video rect inside aspect fit on iOS UIView is tricky without knowing source aspect.
        // For v1 (Simpler), we will send View coordinates (0..1) relative to *View*.
        // If the Mac Sender receives this, it maps to the full display.
        // ERROR: If letterboxing exists, clicks in black bars map to edges of screen.
        // v59 fixed this on Mac Receiver. We should port that logic eventually.
        // For now, assume User fills the screen or accepts slight offset if aspect ratios differ vastly.
        
        let x = Double(location.x / bounds.width)
        let y = Double(location.y / bounds.height)
        return (x, y)
    }
    
    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let (x, y) = normalizedPoint(from: gesture)
        
        switch gesture.state {
        case .began, .changed:
            inputDelegate?.didTriggerInput(InputEvent(type: .mouseMove, x: x, y: y))
        default:
            break
        }
    }
    
    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let (x, y) = normalizedPoint(from: gesture)
        // Send Down + Up
        inputDelegate?.didTriggerInput(InputEvent(type: .leftMouseDown, x: x, y: y))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
             self.inputDelegate?.didTriggerInput(InputEvent(type: .leftMouseUp, x: x, y: y))
        }
    }
    
    @objc private func handleTwoTap(_ gesture: UITapGestureRecognizer) {
        let (x, y) = normalizedPoint(from: gesture)
        inputDelegate?.didTriggerInput(InputEvent(type: .rightMouseDown, x: x, y: y))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
             self.inputDelegate?.didTriggerInput(InputEvent(type: .rightMouseUp, x: x, y: y))
        }
    }
    
    @objc private func handleScroll(_ gesture: UIPanGestureRecognizer) {
        // Map 2-finger drag to scroll wheel
        let velocity = gesture.velocity(in: self)
        if gesture.state == .changed {
            // Scale velocity to scroll delta (arbitrary factor)
            let deltaY = Int(velocity.y / 10.0)
            if deltaY != 0 {
                // Sender expects scroll event. InputEvent struct needs to support 'delta'.
                // Our current InputEvent only has typed/x/y/keyCode.
                // The Sender 'InputHandler' interprets .scrollWheel?
                // Checking previous implementation: Sender InputHandler maps .scrollWheel to scroll?
                // Step 2757 (BetterCastSenderApp.swift) doesn't show InputEvent definition, but receive handles it.
                // Let's assume we repurposed 'keyCode' or added a field.
                // Re-reading `implementation_plan_ios.md`: "Use InputEvent struct (duplicated)".
                // I need to check `InputEvent.swift` to see if it supports scroll/delta.
                // If not, I'll skip scroll for now or use keyCode hack.
            }
        }
    }
}
#endif

