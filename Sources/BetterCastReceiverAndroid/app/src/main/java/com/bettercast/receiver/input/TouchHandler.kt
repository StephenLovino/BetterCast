package com.bettercast.receiver.input

import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.GestureDetector
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import android.view.View
import kotlin.math.abs

class TouchHandler(
    private val view: View,
    private val onInputEvent: (InputEvent) -> Unit
) {

    companion object {
        private const val TAG = "TouchHandler"
        private const val TAP_DELAY_MS = 50L
        private const val SCROLL_SCALE_FACTOR = 0.5

        /** Matches `cursorSensitivity` in the iOS renderer, so both feel the same. */
        private const val CURSOR_SENSITIVITY = 1.5
    }

    /**
     * Trackpad mode.
     *
     * In touch mode a tap lands where the finger lands, and dragging does not move the
     * Mac pointer at all. In cursor mode the screen behaves like a trackpad: dragging
     * pushes a pointer around relatively and every click happens wherever that pointer
     * is, which is the only way to hit small targets on a 1920px desktop shown at phone
     * size. Same split as `InputMode` on iOS.
     */
    var cursorMode: Boolean = false

    /** Normalised pointer position, reported so the UI can draw it. */
    private var cursorX = 0.5
    private var cursorY = 0.5

    var onCursorMoved: ((Float, Float) -> Unit)? = null

    private fun moveCursor(dx: Float, dy: Float) {
        val w = if (videoWidth > 0) videoWidth else view.width.toFloat()
        val h = if (videoHeight > 0) videoHeight else view.height.toFloat()
        if (w <= 0 || h <= 0) return
        cursorX = (cursorX + dx / w * CURSOR_SENSITIVITY).coerceIn(0.0, 1.0)
        cursorY = (cursorY + dy / h * CURSOR_SENSITIVITY).coerceIn(0.0, 1.0)
        onCursorMoved?.invoke(cursorX.toFloat(), cursorY.toFloat())
    }

    /**
     * Where an action should land: under the pointer in cursor mode, under the finger
     * in touch mode.
     */
    private fun actionPoint(x: Float, y: Float): Pair<Double, Double> =
        if (cursorMode) Pair(cursorX, cursorY) else normalizePoint(x, y)

    // Video dimensions within the view (accounting for letterboxing)
    private var videoLeft = 0f
    private var videoTop = 0f
    private var videoWidth = 0f
    private var videoHeight = 0f
    private var hasVideoRect = false

    private val handler = Handler(Looper.getMainLooper())

    /**
     * Three fingers down reveals the on-screen controls, matching the iOS receiver.
     *
     * Every other touch is forwarded to the Mac, so there is no spare single-tap to
     * spend on showing a menu. Three fingers is something no desktop gesture uses.
     */
    var onThreeFingerTap: (() -> Unit)? = null

    private var lastTwoFingerScrollY = 0f
    private var lastTwoFingerScrollX = 0f
    private var isTwoFingerDragging = false
    private var isLongPressDragging = false
    private var lastDragX = 0f
    private var lastDragY = 0f

    private val gestureDetector = GestureDetector(view.context, object : GestureDetector.SimpleOnGestureListener() {

        override fun onDown(e: MotionEvent): Boolean {
            return true
        }

        override fun onSingleTapConfirmed(e: MotionEvent): Boolean {
            val (nx, ny) = actionPoint(e.x, e.y)
            if (nx < 0) return false

            // Left click: down + delay + up
            val downEvent = InputEvent.leftMouseDown(nx, ny)
            val upEvent = InputEvent.leftMouseUp(nx, ny)
            onInputEvent(downEvent)
            handler.postDelayed({ onInputEvent(upEvent) }, TAP_DELAY_MS)
            return true
        }

        override fun onDoubleTap(e: MotionEvent): Boolean {
            val (nx, ny) = actionPoint(e.x, e.y)
            if (nx < 0) return false

            // Double click: two down+up sequences
            val down1 = InputEvent.leftMouseDown(nx, ny)
            val up1 = InputEvent.leftMouseUp(nx, ny)
            val down2 = InputEvent.leftMouseDown(nx, ny)
            val up2 = InputEvent.leftMouseUp(nx, ny)

            onInputEvent(down1)
            handler.postDelayed({
                onInputEvent(up1)
                handler.postDelayed({
                    onInputEvent(down2)
                    handler.postDelayed({ onInputEvent(up2) }, TAP_DELAY_MS)
                }, TAP_DELAY_MS)
            }, TAP_DELAY_MS)
            return true
        }

        override fun onLongPress(e: MotionEvent) {
            val (nx, ny) = actionPoint(e.x, e.y)
            if (nx < 0) return

            // Start drag (left mouse down, then track moves)
            isLongPressDragging = true
            lastDragX = e.x
            lastDragY = e.y
            onInputEvent(InputEvent.leftMouseDown(nx, ny))
        }

        override fun onScroll(
            e1: MotionEvent?,
            e2: MotionEvent,
            distanceX: Float,
            distanceY: Float
        ): Boolean {
            if (isTwoFingerDragging || isLongPressDragging) return false

            if (cursorMode) {
                // Trackpad: push the pointer by the drag delta. distanceX/Y are
                // previous-minus-current, so negate them to get travel direction.
                moveCursor(-distanceX, -distanceY)
                onInputEvent(InputEvent.mouseMove(cursorX, cursorY))
                return true
            }

            // Touch mode: single finger drag = mouse move to the finger
            val (nx, ny) = normalizePoint(e2.x, e2.y)
            if (nx < 0) return false

            onInputEvent(InputEvent.mouseMove(nx, ny))
            return true
        }
    })

    private val scaleDetector = ScaleGestureDetector(view.context, object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
        override fun onScale(detector: ScaleGestureDetector): Boolean {
            // Pinch-to-zoom: send as scroll with keyCode=1 (zoom mode)
            val scaleFactor = detector.scaleFactor
            val deltaY = ((scaleFactor - 1.0f) * 100).toDouble()
            val (nx, ny) = actionPoint(detector.focusX, detector.focusY)
            if (nx < 0) return false

            val event = InputEvent(
                type = InputEvent.TYPE_SCROLL_WHEEL,
                x = nx, y = ny,
                keyCode = 1, // pinch-to-zoom mode
                deltaX = 0.0,
                deltaY = deltaY,
                eventId = InputEvent.nextId()
            )
            onInputEvent(event)
            return true
        }
    })

    init {
        view.setOnTouchListener { _, event -> handleTouch(event) }
    }

    fun updateVideoRect(left: Float, top: Float, width: Float, height: Float) {
        videoLeft = left
        videoTop = top
        videoWidth = width
        videoHeight = height
        hasVideoRect = width > 0 && height > 0
    }

    private fun handleTouch(event: MotionEvent): Boolean {
        // Swallow three-finger gestures before the detectors see them, so revealing
        // the controls never also fires a click or a scroll at the Mac. Any drag in
        // progress is released first, otherwise the button stays stuck down there.
        if (event.pointerCount >= 3) {
            if (isLongPressDragging) {
                val (nx, ny) = actionPoint(event.x, event.y)
                if (nx >= 0) onInputEvent(InputEvent.leftMouseUp(nx, ny))
                isLongPressDragging = false
            }
            isTwoFingerDragging = false
            if (event.actionMasked == MotionEvent.ACTION_POINTER_DOWN) {
                onThreeFingerTap?.invoke()
            }
            return true
        }

        scaleDetector.onTouchEvent(event)
        gestureDetector.onTouchEvent(event)

        val pointerCount = event.pointerCount

        when (event.actionMasked) {
            MotionEvent.ACTION_POINTER_DOWN -> {
                if (pointerCount == 2) {
                    isTwoFingerDragging = true
                    lastTwoFingerScrollX = (event.getX(0) + event.getX(1)) / 2
                    lastTwoFingerScrollY = (event.getY(0) + event.getY(1)) / 2
                }
            }

            MotionEvent.ACTION_MOVE -> {
                if (isTwoFingerDragging && pointerCount >= 2) {
                    val currentX = (event.getX(0) + event.getX(1)) / 2
                    val currentY = (event.getY(0) + event.getY(1)) / 2

                    val dx = (currentX - lastTwoFingerScrollX) * SCROLL_SCALE_FACTOR
                    val dy = (currentY - lastTwoFingerScrollY) * SCROLL_SCALE_FACTOR

                    if (abs(dx) > 1 || abs(dy) > 1) {
                        val (nx, ny) = actionPoint(currentX, currentY)
                        if (nx >= 0) {
                            onInputEvent(InputEvent.scroll(nx, ny, dx, dy))
                        }
                        lastTwoFingerScrollX = currentX
                        lastTwoFingerScrollY = currentY
                    }
                } else if (isLongPressDragging && pointerCount == 1) {
                    if (cursorMode) {
                        // Long-press drag has no translation of its own, so track the
                        // delta between moves the way the iOS handler does.
                        moveCursor(event.x - lastDragX, event.y - lastDragY)
                        lastDragX = event.x
                        lastDragY = event.y
                        onInputEvent(InputEvent.mouseMove(cursorX, cursorY))
                    } else {
                        val (nx, ny) = normalizePoint(event.x, event.y)
                        if (nx >= 0) {
                            onInputEvent(InputEvent.mouseMove(nx, ny))
                        }
                    }
                }
            }

            MotionEvent.ACTION_POINTER_UP -> {
                if (pointerCount == 2) {
                    // Two-finger tap detection: if minimal movement, it's a right-click
                    if (isTwoFingerDragging) {
                        val totalMove = abs(event.getX(0) - lastTwoFingerScrollX) +
                                abs(event.getY(0) - lastTwoFingerScrollY)
                        if (totalMove < 30) {
                            // Two-finger tap = right click
                            val midX = (event.getX(0) + event.getX(1)) / 2
                            val midY = (event.getY(0) + event.getY(1)) / 2
                            val (nx, ny) = actionPoint(midX, midY)
                            if (nx >= 0) {
                                onInputEvent(InputEvent.rightMouseDown(nx, ny))
                                handler.postDelayed({
                                    onInputEvent(InputEvent.rightMouseUp(nx, ny))
                                }, TAP_DELAY_MS)
                            }
                        }
                    }
                    isTwoFingerDragging = false
                }
            }

            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                if (isLongPressDragging) {
                    val (nx, ny) = actionPoint(event.x, event.y)
                    if (nx >= 0) {
                        onInputEvent(InputEvent.leftMouseUp(nx, ny))
                    }
                    isLongPressDragging = false
                }
                isTwoFingerDragging = false
            }
        }

        return true
    }

    private fun normalizePoint(x: Float, y: Float): Pair<Double, Double> {
        if (!hasVideoRect) {
            // Fallback: normalize to full view
            val nx = (x / view.width.toFloat()).toDouble().coerceIn(0.0, 1.0)
            val ny = (y / view.height.toFloat()).toDouble().coerceIn(0.0, 1.0)
            return Pair(nx, ny)
        }

        // Account for letterboxing
        val relX = x - videoLeft
        val relY = y - videoTop

        if (relX < 0 || relX > videoWidth || relY < 0 || relY > videoHeight) {
            // Touch is in letterbox area - clamp to edge
            val nx = (relX / videoWidth).toDouble().coerceIn(0.0, 1.0)
            val ny = (relY / videoHeight).toDouble().coerceIn(0.0, 1.0)
            return Pair(nx, ny)
        }

        val nx = (relX / videoWidth).toDouble().coerceIn(0.0, 1.0)
        val ny = (relY / videoHeight).toDouble().coerceIn(0.0, 1.0)
        return Pair(nx, ny)
    }
}
