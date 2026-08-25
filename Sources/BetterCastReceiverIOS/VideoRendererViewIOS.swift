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

class VideoRendererViewIOS: UIView, VideoRendererIOS, UIGestureRecognizerDelegate {

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
        // Recognisers swallow the touches they act on by default, which cut off
        // touchesMoved the instant a drag was recognised: the press and the release
        // arrived with no movement between them, so nothing on the Mac actually moved.
        pan.cancelsTouchesInView = false
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
        // latency to every single tap. The dedicated doubleTap recognizer carries an explicit
        // click count instead: macOS does NOT infer a double-click from two clicks arriving
        // close together, it only reports one when the event says so.

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

        // Every recogniser above is for fingers. A Pencil is handled directly in
        // touchesBegan/Moved/Ended so a stroke starts on contact, and the delegate
        // keeps these from firing a second, pressureless click on top of it.
        gestureRecognizers?.forEach { $0.delegate = self }
    }

    // MARK: - Full-rate drag sampling

    /// True while a touch-mode long-press drag is in flight.
    ///
    /// UIKit delivers gesture callbacks once per display refresh, but the digitizer
    /// samples well above that, and every sample in between is held in the event's
    /// coalesced list. Dragging straight off the recognizer therefore threw away most
    /// of the stroke: a quick diagonal drag arrived on the Mac as a handful of long
    /// jumps, so selections landed short and anything following the finger stepped
    /// instead of gliding. While this is set, movement comes from `touchesMoved`
    /// below and the recognizer stops sending its own coarse samples.
    private var isTouchDragActive = false

    /// Where the current touch-mode drag was last seen, so the release can be sent even
    /// if the finger lifts somewhere that maps to nothing.
    private var lastTouchDragPoint: (Double, Double)?

    /// Whether touchesMoved has delivered anything during this drag. When it has, the
    /// recogniser stays quiet so the same movement is not sent twice at two rates.
    private var touchSamplingDelivered = false

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)

        if let pencil = touches.first(where: { $0.type == .pencil }) {
            streamSamples(for: pencil, event: event, type: .mouseMove)
            return
        }

        guard isTouchDragActive,
              inputMode == .touch,
              let touch = touches.first,
              (event?.allTouches?.count ?? 1) == 1 else { return }

        touchSamplingDelivered = true
        streamSamples(for: touch, event: event, type: .mouseMove)
    }

    /// Forward every sample UIKit gathered since the last callback, oldest first,
    /// falling back to the touch itself when it coalesced nothing.
    private func streamSamples(for touch: UITouch, event: UIEvent?, type: InputEventType) {
        let coalesced = event?.coalescedTouches(for: touch) ?? []
        for sample in (coalesced.isEmpty ? [touch] : coalesced) {
            guard let (x, y) = normalizedPoint(at: sample.location(in: self)) else { continue }
            inputDelegate?.didTriggerInput(makeEvent(type: type, x: x, y: y, touch: sample))
        }
    }

    /// Build a wire event, attaching stylus detail when the touch came from a Pencil.
    /// A finger sends no pressure at all, which is what keeps it an ordinary click.
    private func makeEvent(type: InputEventType, x: Double, y: Double, touch: UITouch) -> InputEvent {
        guard touch.type == .pencil else {
            return InputEvent(type: type, x: x, y: y)
        }
        let maxForce = touch.maximumPossibleForce
        // maximumPossibleForce is 0 on hardware that cannot weigh the touch. Reporting
        // full pressure there is better than reporting none: the stroke still draws.
        let pressure = maxForce > 0 ? min(1.0, Double(touch.force / maxForce)) : 1.0
        return InputEvent(
            type: type,
            x: x,
            y: y,
            pressure: pressure,
            altitude: Double(touch.altitudeAngle),
            azimuth: Double(touch.azimuthAngle(in: self))
        )
    }

    // MARK: - Apple Pencil

    /// A Pencil drives the Mac directly rather than through the finger gestures.
    ///
    /// Drawing needs contact to register the instant the tip lands, so waiting on a
    /// long press or a tap recogniser to settle would clip the start of every stroke.
    /// `gestureRecognizer(_:shouldReceive:)` below keeps the finger recognisers out of
    /// the way so a Pencil tap cannot also arrive as a second, pressureless click.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        guard let pencil = touches.first(where: { $0.type == .pencil }),
              let (x, y) = normalizedPoint(at: pencil.location(in: self)) else { return }
        inputDelegate?.didTriggerInput(makeEvent(type: .leftMouseDown, x: x, y: y, touch: pencil))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        endPencil(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        endPencil(touches)
    }

    private func endPencil(_ touches: Set<UITouch>) {
        guard let pencil = touches.first(where: { $0.type == .pencil }),
              let (x, y) = normalizedPoint(at: pencil.location(in: self)) else { return }
        // Lift reports no pressure, which is also what tells the Mac to take the stylus
        // back out of proximity.
        inputDelegate?.didTriggerInput(
            InputEvent(type: .leftMouseUp, x: x, y: y, pressure: 0,
                       altitude: Double(pencil.altitudeAngle),
                       azimuth: Double(pencil.azimuthAngle(in: self)))
        )
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        touch.type != .pencil
    }

    /// Toggle between aspect-fill (full screen) and aspect-fit (letterbox)
    var isAspectFill: Bool = true {
        didSet {
            videoLayer.videoGravity = isAspectFill ? .resizeAspectFill : .resizeAspect
        }
    }
    
    private func normalizedPoint(from gesture: UIGestureRecognizer) -> (Double, Double)? {
        normalizedPoint(at: gesture.location(in: self))
    }

    /// Map a point in this view to the 0-1 position of the same pixel in the streamed
    /// image, accounting for whichever way the video is currently fitted.
    private func normalizedPoint(at location: CGPoint) -> (Double, Double)? {
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
        // Touch mode: one finger drags, the way a touchscreen should. This used to be
        // ignored entirely, leaving a 0.3s press-and-hold as the only way to drag
        // anything — undiscoverable, and it made touch mode look broken even though
        // taps were landing correctly. Two fingers already mean scroll, so one finger
        // is free to mean drag. Movement itself is streamed by touchesMoved at the
        // digitizer's full rate; this only marks where the drag starts and stops.
        if inputMode == .touch {
            let point = normalizedPoint(from: gesture) ?? lastTouchDragPoint
            switch gesture.state {
            case .began:
                guard let (x, y) = point else { return }
                lastTouchDragPoint = (x, y)
                touchSamplingDelivered = false
                isTouchDragActive = true
                inputDelegate?.didTriggerInput(InputEvent(type: .mouseMove, x: x, y: y))
                inputDelegate?.didTriggerInput(InputEvent(type: .leftMouseDown, x: x, y: y))
            case .changed:
                if let p = point { lastTouchDragPoint = p }
                // Normally touchesMoved carries the movement at the digitizer's full
                // rate. If it is not being delivered, fall back to the recogniser's own
                // coarser samples rather than sending no movement at all.
                if !touchSamplingDelivered, let (x, y) = point {
                    inputDelegate?.didTriggerInput(InputEvent(type: .mouseMove, x: x, y: y))
                }
            case .ended, .cancelled, .failed:
                // Release even when the finger lifts outside the video: `point` falls
                // back to the last good position rather than leaving the button held.
                guard isTouchDragActive else { return }
                isTouchDragActive = false
                if let (x, y) = point {
                    inputDelegate?.didTriggerInput(InputEvent(type: .leftMouseUp, x: x, y: y))
                }
                lastTouchDragPoint = nil
            default:
                break
            }
            return
        }

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
        // The second click carries clickCount 2. Two clicks close together are NOT read
        // as a double-click by macOS on their own, which is why double-tap used to open
        // nothing and select no words: the click state has to be stated explicitly.
        inputDelegate?.didTriggerInput(InputEvent(type: .leftMouseDown, x: x, y: y, clickCount: 1))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            self.inputDelegate?.didTriggerInput(InputEvent(type: .leftMouseUp, x: x, y: y, clickCount: 1))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            self.inputDelegate?.didTriggerInput(InputEvent(type: .leftMouseDown, x: x, y: y, clickCount: 2))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            self.inputDelegate?.didTriggerInput(InputEvent(type: .leftMouseUp, x: x, y: y, clickCount: 2))
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
            // Dragging in touch mode is handled by handlePan now, from the first
            // movement rather than after a hold. Doing it here as well would press the
            // button twice for one gesture.
            return
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

