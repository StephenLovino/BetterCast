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
    }

    // Video dimensions within the view (accounting for letterboxing)
    private var videoLeft = 0f
    private var videoTop = 0f
    private var videoWidth = 0f
    private var videoHeight = 0f
    private var hasVideoRect = false

    private val handler = Handler(Looper.getMainLooper())

    private var lastTwoFingerScrollY = 0f
    private var lastTwoFingerScrollX = 0f
    private var isTwoFingerDragging = false
    private var isLongPressDragging = false

    private val gestureDetector = GestureDetector(view.context, object : GestureDetector.SimpleOnGestureListener() {

        override fun onDown(e: MotionEvent): Boolean {
            return true
        }

        override fun onSingleTapConfirmed(e: MotionEvent): Boolean {
            val (nx, ny) = normalizePoint(e.x, e.y)
            if (nx < 0) return false

            // Left click: down + delay + up
            val downEvent = InputEvent.leftMouseDown(nx, ny)
            val upEvent = InputEvent.leftMouseUp(nx, ny)
            onInputEvent(downEvent)
            handler.postDelayed({ onInputEvent(upEvent) }, TAP_DELAY_MS)
            return true
        }

        override fun onDoubleTap(e: MotionEvent): Boolean {
            val (nx, ny) = normalizePoint(e.x, e.y)
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
            val (nx, ny) = normalizePoint(e.x, e.y)
            if (nx < 0) return

            // Start drag (left mouse down, then track moves)
            isLongPressDragging = true
            onInputEvent(InputEvent.leftMouseDown(nx, ny))
        }

        override fun onScroll(
            e1: MotionEvent?,
            e2: MotionEvent,
            distanceX: Float,
            distanceY: Float
        ): Boolean {
            if (isTwoFingerDragging || isLongPressDragging) return false

            // Single finger drag = mouse move
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
            val (nx, ny) = normalizePoint(detector.focusX, detector.focusY)
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
                        val (nx, ny) = normalizePoint(currentX, currentY)
                        if (nx >= 0) {
                            onInputEvent(InputEvent.scroll(nx, ny, dx, dy))
                        }
                        lastTwoFingerScrollX = currentX
                        lastTwoFingerScrollY = currentY
                    }
                } else if (isLongPressDragging && pointerCount == 1) {
                    val (nx, ny) = normalizePoint(event.x, event.y)
                    if (nx >= 0) {
                        onInputEvent(InputEvent.mouseMove(nx, ny))
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
                            val (nx, ny) = normalizePoint(midX, midY)
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
                    val (nx, ny) = normalizePoint(event.x, event.y)
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
