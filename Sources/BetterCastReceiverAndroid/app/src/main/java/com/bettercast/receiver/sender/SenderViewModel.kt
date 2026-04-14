package com.bettercast.receiver.sender

import android.app.Application
import android.content.Intent
import android.os.Build
import android.util.DisplayMetrics
import android.util.Log
import android.view.WindowManager
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.bettercast.receiver.network.ConnectionState
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

enum class SenderState {
    IDLE,
    WAITING,
    CONNECTED,
    ERROR
}

class SenderViewModel(application: Application) : AndroidViewModel(application) {

    companion object {
        private const val TAG = "SenderViewModel"
    }

    private val _state = MutableStateFlow(SenderState.IDLE)
    val state: StateFlow<SenderState> = _state.asStateFlow()

    private val _statusMessage = MutableStateFlow("Ready to cast")
    val statusMessage: StateFlow<String> = _statusMessage.asStateFlow()

    // Triggers the Activity to launch MediaProjection permission intent
    private val _requestProjection = MutableStateFlow(false)
    val requestProjection: StateFlow<Boolean> = _requestProjection.asStateFlow()

    val tcpSender = TcpSender()
    private var videoEncoder: VideoEncoder? = null
    private var orientationPollJob: Job? = null

    init {
        // Observe TCP connection state
        viewModelScope.launch {
            tcpSender.connectionState.collect { connState ->
                when (connState) {
                    ConnectionState.CONNECTED -> {
                        _state.value = SenderState.CONNECTED
                        _statusMessage.value = "Casting to Mac receiver"
                        Log.i(TAG, "Receiver connected")
                    }
                    ConnectionState.LISTENING -> {
                        if (_state.value == SenderState.CONNECTED) {
                            // Was connected, receiver disconnected
                            _state.value = SenderState.WAITING
                            _statusMessage.value = "Receiver disconnected. Waiting..."
                        }
                    }
                    ConnectionState.ERROR -> {
                        _state.value = SenderState.ERROR
                        _statusMessage.value = tcpSender.errorMessage.value ?: "Connection error"
                    }
                    ConnectionState.IDLE -> {}
                }
            }
        }
    }

    fun startSending() {
        if (_state.value != SenderState.IDLE && _state.value != SenderState.ERROR) return
        _requestProjection.value = true
    }

    /**
     * Called by the Activity after the user grants screen capture permission.
     */
    fun onProjectionGranted(resultCode: Int, data: Intent) {
        _requestProjection.value = false

        // 1. Get actual screen dimensions and scale down
        val (encWidth, encHeight) = getScaledScreenSize(maxDimension = 1280)

        // 2. Create and start encoder with real screen aspect ratio
        val encoder = VideoEncoder(width = encWidth, height = encHeight, bitrate = 8_000_000, fps = 30)
        encoder.start()
        videoEncoder = encoder

        // 2. Wire encoder output to TCP sender
        encoder.onEncodedFrame = { frame ->
            tcpSender.sendFrame(frame)
        }

        // 3. Wire keyframe requests from receiver to encoder
        tcpSender.onKeyframeRequested = {
            encoder.forceKeyframe()
        }

        // 4. Store projection data for the foreground service
        ScreenCaptureService.projectionResultCode = resultCode
        ScreenCaptureService.projectionResultData = data
        ScreenCaptureService.videoEncoder = encoder

        // 5. Start foreground service (required for MediaProjection on Android 10+)
        val app = getApplication<Application>()
        val serviceIntent = Intent(app, ScreenCaptureService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            app.startForegroundService(serviceIntent)
        } else {
            app.startService(serviceIntent)
        }

        // 6. Start orientation polling to detect rotation while casting
        startOrientationPolling()

        // 7. Start TCP server and wait for Mac receiver
        val port = tcpSender.startListening()
        if (port > 0) {
            _state.value = SenderState.WAITING
            _statusMessage.value = "Waiting for Mac receiver on port $port..."
            Log.i(TAG, "TCP server listening on port $port")
        } else {
            _state.value = SenderState.ERROR
            _statusMessage.value = "Failed to start server"
        }
    }

    /**
     * Get screen size scaled so the largest dimension is maxDimension.
     * Preserves aspect ratio and ensures both dimensions are even (required by MediaCodec).
     */
    private fun getScaledScreenSize(maxDimension: Int): Pair<Int, Int> {
        val wm = getApplication<Application>().getSystemService(android.content.Context.WINDOW_SERVICE) as WindowManager
        val metrics = DisplayMetrics()
        @Suppress("DEPRECATION")
        wm.defaultDisplay.getRealMetrics(metrics)

        val screenW = metrics.widthPixels
        val screenH = metrics.heightPixels

        val scale = maxDimension.toFloat() / maxOf(screenW, screenH).toFloat()
        var w = (screenW * scale).toInt()
        var h = (screenH * scale).toInt()

        // MediaCodec requires even dimensions
        w = w and 0x7FFFFFFE // round down to even
        h = h and 0x7FFFFFFE

        Log.d(TAG, "Screen: ${screenW}x${screenH} -> Encode: ${w}x${h}")
        return Pair(w, h)
    }

    /**
     * Called when the device orientation changes while casting.
     */
    fun onOrientationChanged() {
        // Also triggered by polling, but allow immediate re-check
        checkAndApplyOrientationChange()
    }

    /**
     * Polls screen dimensions every 500ms while casting.
     * More reliable than onConfigurationChanged alone — catches app-driven rotations,
     * split-screen changes, and any other display size changes.
     */
    private fun startOrientationPolling() {
        orientationPollJob?.cancel()
        orientationPollJob = viewModelScope.launch {
            while (isActive) {
                delay(500)
                checkAndApplyOrientationChange()
            }
        }
    }

    private fun stopOrientationPolling() {
        orientationPollJob?.cancel()
        orientationPollJob = null
    }

    private fun checkAndApplyOrientationChange() {
        val oldEncoder = videoEncoder ?: return
        if (_state.value != SenderState.WAITING && _state.value != SenderState.CONNECTED) return

        val (newW, newH) = getScaledScreenSize(maxDimension = 1280)

        // Skip if dimensions haven't actually changed
        if (newW == oldEncoder.width && newH == oldEncoder.height) return

        Log.i(TAG, "Orientation changed: ${oldEncoder.width}x${oldEncoder.height} -> ${newW}x${newH}")

        // 1. Create new encoder FIRST (before stopping old — keeps a valid surface at all times)
        val encoder = VideoEncoder(width = newW, height = newH, bitrate = 8_000_000, fps = 30)
        encoder.start()

        // 2. Wire callbacks to new encoder
        encoder.onEncodedFrame = { frame ->
            tcpSender.sendFrame(frame)
        }
        tcpSender.onKeyframeRequested = {
            encoder.forceKeyframe()
        }

        // 3. Switch VirtualDisplay to new encoder's surface BEFORE stopping old encoder
        ScreenCaptureService.videoEncoder = encoder
        ScreenCaptureService.instance?.createVirtualDisplay()

        // 4. NOW stop old encoder — VirtualDisplay already uses the new surface
        oldEncoder.stop()
        videoEncoder = encoder

        // 5. Force an immediate keyframe so the receiver can decode right away
        encoder.forceKeyframe()
    }

    fun onProjectionDenied() {
        _requestProjection.value = false
        _statusMessage.value = "Screen capture permission denied"
    }

    fun stopSending() {
        stopOrientationPolling()

        val app = getApplication<Application>()
        app.stopService(Intent(app, ScreenCaptureService::class.java))

        videoEncoder?.stop()
        videoEncoder = null
        tcpSender.stopListening()

        _state.value = SenderState.IDLE
        _statusMessage.value = "Ready to cast"
        Log.i(TAG, "Sending stopped")
    }

    fun retry() {
        stopSending()
    }

    override fun onCleared() {
        super.onCleared()
        stopSending()
        tcpSender.destroy()
        videoEncoder?.destroy()
    }
}
