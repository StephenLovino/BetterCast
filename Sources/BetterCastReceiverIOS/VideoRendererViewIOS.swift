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

enum InputMode {
    case touch     // Direct: tap position = cursor position
    case cursor    // Trackpad: pan moves cursor relatively
}

class VideoRendererViewIOS: UIView, VideoRendererIOS {

    weak var inputDelegate: InputDelegate?

    /// Actual video dimensions, updated from decoded frames for aspect-ratio-aware coordinate mapping
    var contentSize: CGSize = CGSize(width: 1920, height: 1080)

    /// Input mode: touch (direct) or cursor (trackpad-style relative movement)
    var inputMode: InputMode = .touch {
        didSet {
            virtualCursor.isHidden = (inputMode != .cursor)
            updateVirtualCursorPosition()
        }
    }

    /// Virtual cursor position for trackpad mode (normalized 0-1)
    private var cursorX: Double = 0.5
    private var cursorY: Double = 0.5

    /// Trackpad sensitivity multiplier
    private let cursorSensitivity: Double = 1.5

    /// Last finger location during a long-press drag (cursor mode)
    private var lastLongPressLocation: CGPoint = .zero

    /// Visible iOS cursor for trackpad mode — separate from finger position
    /// Styled to match the macOS pointer: white fill with a tight black outline.
    private let virtualCursor: UIImageView = {
        let iv = UIImageView()
        if #available(iOS 13.0, *) {
            let cfg = UIImage.SymbolConfiguration(pointSize: 14, weight: .black)
            iv.image = UIImage(systemName: "cursorarrow.fill", withConfiguration: cfg)
        }
        iv.tintColor = .white
        // Tight black shadow at zero offset gives the macOS-style outline look
        iv.layer.shadowColor = UIColor.black.cgColor
        iv.layer.shadowOpacity = 1.0
        iv.layer.shadowRadius = 0.6
        iv.layer.shadowOffset = .zero
        iv.isHidden = true
        iv.isUserInteractionEnabled = false
        return iv
    }()
    private let virtualCursorSize = CGSize(width: 16, height: 16)
    
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
        addSubview(virtualCursor)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayer()
        setupGestures()
        addSubview(virtualCursor)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateVirtualCursorPosition()
    }
    
    private func setupLayer() {
        videoLayer.videoGravity = .resizeAspectFill // Fill screen by default (like Duet Display)
        // Use timebase for smooth playback (standard remote desktop technique)
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
            LogManager.shared.log("VideoRenderer: Layer failed, flushing")
            videoLayer.flush()
        }

        // Force immediate display — no queue buildup since each frame renders instantly
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) as? [NSMutableDictionary], let dict = attachments.first {
            dict[kCMSampleAttachmentKey_DisplayImmediately] = true
        }

        videoLayer.enqueue(sampleBuffer)

        // Update contentSize from video frame dimensions for aspect-ratio-aware input mapping
        if let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            let dim = CMVideoFormatDescriptionGetDimensions(format)
            let width = CGFloat(dim.width)
            let height = CGFloat(dim.height)
            if width > 0 && height > 0 && (contentSize.width != width || contentSize.height != height) {
                contentSize = CGSize(width: width, height: height)
            }
        }
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
        
        // 4. Scroll (2 Finger Pan) — strictly 2 fingers so 3-finger swipes pass through
        let scrollPan = UIPanGestureRecognizer(target: self, action: #selector(handleScroll(_:)))
        scrollPan.minimumNumberOfTouches = 2
        scrollPan.maximumNumberOfTouches = 2
        addGestureRecognizer(scrollPan)

        // 5. Pinch to Zoom
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        addGestureRecognizer(pinch)

        // 6. Double Tap (Double Click)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.numberOfTouchesRequired = 1
        addGestureRecognizer(doubleTap)
        // Note: intentionally NOT calling tap.require(toFail: doubleTap) — that adds ~300ms
        // latency to every single tap. Two quick taps will fire as two single clicks, which
        // macOS interprets as a double-click anyway. The dedicated doubleTap recognizer also
        // still fires for tighter double-click timing.

        // 7. Long Press (Click and Drag)
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.3
        addGestureRecognizer(longPress)

        // 8. Three-finger swipe — Mission Control / App Exposé / Switch Space
        for direction in [UISwipeGestureRecognizer.Direction.up,
                          .down, .left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(handleThreeFingerSwipe(_:)))
            swipe.direction = direction
            swipe.numberOfTouchesRequired = 3
            addGestureRecognizer(swipe)
        }
    }

    /// Toggle between aspect-fill (full screen) and aspect-fit (letterbox)
    var isAspectFill: Bool = true {
        didSet {
            videoLayer.videoGravity = isAspectFill ? .resizeAspectFill : .resizeAspect
        }
    }
    
    private func normalizedPoint(from gesture: UIGestureRecognizer) -> (Double, Double)? {
        let location = gesture.location(in: self)
        let viewSize = bounds.size

        guard viewSize.width > 0, viewSize.height > 0,
              contentSize.width > 0, contentSize.height > 0 else { return nil }

        let widthRatio = viewSize.width / contentSize.width
        let heightRatio = viewSize.height / contentSize.height

        if isAspectFill {
            // Aspect fill: video is scaled up so it covers the entire view, edges are cropped
            let scale = max(widthRatio, heightRatio)
            let videoWidth = contentSize.width * scale
            let videoHeight = contentSize.height * scale
            let xOffset = (viewSize.width - videoWidth) / 2.0
            let yOffset = (viewSize.height - videoHeight) / 2.0

            let normX = Double((location.x - xOffset) / videoWidth)
            let normY = Double((location.y - yOffset) / videoHeight)
            return (max(0, min(1, normX)), max(0, min(1, normY)))
        } else {
            // Aspect fit: video is letterboxed, taps in bars are ignored
            let scale = min(widthRatio, heightRatio)
            let videoWidth = contentSize.width * scale
            let videoHeight = contentSize.height * scale
            let xOffset = (viewSize.width - videoWidth) / 2.0
            let yOffset = (viewSize.height - videoHeight) / 2.0

            let relX = location.x - xOffset
            let relY = location.y - yOffset

            if relX < 0 || relX > videoWidth || relY < 0 || relY > videoHeight {
                return nil
            }

            let normX = Double(relX / videoWidth)
            let normY = Double(relY / videoHeight)
            return (normX, normY)
        }
    }
    
    // MARK: - Cursor mode helpers

    /// Move virtual cursor by normalized delta (for trackpad mode)
    private func moveCursor(dx: CGFloat, dy: CGFloat) {
        let viewSize = bounds.size
        guard viewSize.width > 0, viewSize.height > 0 else { return }

        // Convert pixel delta to normalized delta, scaled by sensitivity
        cursorX += Double(dx / viewSize.width) * cursorSensitivity
        cursorY += Double(dy / viewSize.height) * cursorSensitivity
        cursorX = max(0, min(1, cursorX))
        cursorY = max(0, min(1, cursorY))
        updateVirtualCursorPosition()
    }

    private func updateVirtualCursorPosition() {
        guard inputMode == .cursor else { return }
        let viewSize = bounds.size
        guard viewSize.width > 0, viewSize.height > 0 else { return }
        let x = CGFloat(cursorX) * viewSize.width
        let y = CGFloat(cursorY) * viewSize.height
        // Anchor the arrow tip near the top-left of the icon
        virtualCursor.frame = CGRect(
            x: x - 2,
            y: y - 2,
            width: virtualCursorSize.width,
            height: virtualCursorSize.height
        )
    }

    // MARK: - Gesture Handlers

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        // Touch mode: panning the finger does NOT move the Mac cursor.
        // Tap = click, long-press = drag. This keeps the Mac cursor from chasing the finger.
        guard inputMode == .cursor else { return }
        switch gesture.state {
        case .began, .changed:
            let translation = gesture.translation(in: self)
            moveCursor(dx: translation.x, dy: translation.y)
            gesture.setTranslation(.zero, in: self)
            inputDelegate?.didTriggerInput(InputEvent(type: .mouseMove, x: cursorX, y: cursorY))
        default:
            break
        }
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let (x, y): (Double, Double)
        if inputMode == .cursor {
            (x, y) = (cursorX, cursorY)
        } else {
            guard let pt = normalizedPoint(from: gesture) else { return }
            (x, y) = pt
        }
        // Send a mouseMove first so AppKit/SwiftUI hover-aware UI engages before the click.
        // CGEvent moves the cursor on .leftMouseDown too, but some Mac UI only reacts after
        // it sees a hover transition.
        inputDelegate?.didTriggerInput(InputEvent(type: .mouseMove, x: x, y: y))
        inputDelegate?.didTriggerInput(InputEvent(type: .leftMouseDown, x: x, y: y))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.inputDelegate?.didTriggerInput(InputEvent(type: .leftMouseUp, x: x, y: y))
        }
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        let (x, y): (Double, Double)
        if inputMode == .cursor {
            (x, y) = (cursorX, cursorY)
        } else {
            guard let pt = normalizedPoint(from: gesture) else { return }
            (x, y) = pt
        }
        inputDelegate?.didTriggerInput(InputEvent(type: .leftMouseDown, x: x, y: y))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            self.inputDelegate?.didTriggerInput(InputEvent(type: .leftMouseUp, x: x, y: y))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            self.inputDelegate?.didTriggerInput(InputEvent(type: .leftMouseDown, x: x, y: y))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            self.inputDelegate?.didTriggerInput(InputEvent(type: .leftMouseUp, x: x, y: y))
        }
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        if inputMode == .cursor {
            switch gesture.state {
            case .began:
                lastLongPressLocation = gesture.location(in: self)
                inputDelegate?.didTriggerInput(InputEvent(type: .leftMouseDown, x: cursorX, y: cursorY))
            case .changed:
                // Long-press doesn't give translation, so we compute delta from last location
                let current = gesture.location(in: self)
                let dx = current.x - lastLongPressLocation.x
                let dy = current.y - lastLongPressLocation.y
                lastLongPressLocation = current
                moveCursor(dx: dx, dy: dy)
                inputDelegate?.didTriggerInput(InputEvent(type: .mouseMove, x: cursorX, y: cursorY))
            case .ended, .cancelled:
                inputDelegate?.didTriggerInput(InputEvent(type: .leftMouseUp, x: cursorX, y: cursorY))
            default:
                break
            }
        } else {
            guard let (x, y) = normalizedPoint(from: gesture) else { return }
            switch gesture.state {
            case .began:
                inputDelegate?.didTriggerInput(InputEvent(type: .leftMouseDown, x: x, y: y))
            case .changed:
                inputDelegate?.didTriggerInput(InputEvent(type: .mouseMove, x: x, y: y))
            case .ended, .cancelled:
                inputDelegate?.didTriggerInput(InputEvent(type: .leftMouseUp, x: x, y: y))
            default:
                break
            }
        }
    }

    @objc private func handleTwoTap(_ gesture: UITapGestureRecognizer) {
        let (x, y): (Double, Double)
        if inputMode == .cursor {
            (x, y) = (cursorX, cursorY)
        } else {
            guard let pt = normalizedPoint(from: gesture) else { return }
            (x, y) = pt
        }
        inputDelegate?.didTriggerInput(InputEvent(type: .mouseMove, x: x, y: y))
        inputDelegate?.didTriggerInput(InputEvent(type: .rightMouseDown, x: x, y: y))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.inputDelegate?.didTriggerInput(InputEvent(type: .rightMouseUp, x: x, y: y))
        }
    }
    
    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        if gesture.state == .changed {
            // Convert scale to a magnitude delta (scale 1.0 = no change)
            let magnitude = Double(gesture.scale - 1.0) * 100.0
            if magnitude != 0 {
                // keyCode 1 signals magnification gesture to the sender
                inputDelegate?.didTriggerInput(InputEvent(type: .scrollWheel, keyCode: 1, deltaY: magnitude))
            }
            gesture.scale = 1.0 // Reset for incremental deltas
        }
    }

    @objc private func handleThreeFingerSwipe(_ gesture: UISwipeGestureRecognizer) {
        // Maps to macOS keyboard shortcuts via .command keyCode 600..603.
        // Sender posts Ctrl+Arrow which is the default macOS Mission Control / Spaces binding.
        // Convention: swiping fingers LEFT moves you to the NEXT space on the right.
        let keyCode: UInt16
        switch gesture.direction {
        case .up:    keyCode = 600 // Mission Control     (Ctrl+Up)
        case .down:  keyCode = 601 // App Exposé          (Ctrl+Down)
        case .left:  keyCode = 603 // Switch space right  (Ctrl+Right)
        case .right: keyCode = 602 // Switch space left   (Ctrl+Left)
        default: return
        }
        inputDelegate?.didTriggerInput(InputEvent(type: .command, keyCode: keyCode))
    }

    @objc private func handleScroll(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .changed {
            let translation = gesture.translation(in: self)
            let dx = Double(-translation.x)
            let dy = Double(-translation.y)
            if dx != 0 || dy != 0 {
                inputDelegate?.didTriggerInput(InputEvent(type: .scrollWheel, deltaX: dx, deltaY: dy))
            }
            // Reset so we get incremental deltas, not cumulative
            gesture.setTranslation(.zero, in: self)
        }
    }
}
#endif

