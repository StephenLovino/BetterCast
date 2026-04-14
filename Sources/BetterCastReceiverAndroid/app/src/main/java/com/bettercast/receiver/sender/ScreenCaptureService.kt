package com.bettercast.receiver.sender

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.IBinder
import android.util.Log

class ScreenCaptureService : Service() {

    companion object {
        private const val TAG = "ScreenCaptureService"
        private const val NOTIFICATION_ID = 1001
        private const val CHANNEL_ID = "screen_capture"

        // Set these before starting the service
        var projectionResultCode: Int = 0
        var projectionResultData: Intent? = null
        var videoEncoder: VideoEncoder? = null
        var instance: ScreenCaptureService? = null
    }

    private var mediaProjection: MediaProjection? = null
    private var virtualDisplay: VirtualDisplay? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, buildNotification())

        val resultData = projectionResultData
        if (resultData == null) {
            Log.e(TAG, "No projection result data — stopping")
            stopSelf()
            return START_NOT_STICKY
        }

        instance = this

        // Only create MediaProjection on first start (not on recreate)
        if (mediaProjection == null) {
            try {
                val mpManager = getSystemService(MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
                mediaProjection = mpManager.getMediaProjection(projectionResultCode, resultData)

                mediaProjection?.registerCallback(object : MediaProjection.Callback() {
                    override fun onStop() {
                        Log.i(TAG, "MediaProjection stopped by system")
                        releaseVirtualDisplay()
                        stopSelf()
                    }
                }, null)
            } catch (e: Exception) {
                Log.e(TAG, "Failed to create MediaProjection", e)
                stopSelf()
                return START_NOT_STICKY
            }
        }

        createVirtualDisplay()
        return START_NOT_STICKY
    }

    /**
     * Create or update the VirtualDisplay with the current encoder's dimensions and surface.
     * On first call, creates via MediaProjection.createVirtualDisplay().
     * On subsequent calls (orientation change), uses resize()+setSurface() because
     * Android 14+ forbids calling createVirtualDisplay() more than once per projection.
     */
    fun createVirtualDisplay() {
        val encoder = videoEncoder
        if (encoder == null) {
            Log.e(TAG, "No video encoder for VirtualDisplay")
            return
        }
        val surface = encoder.inputSurface
        if (surface == null) {
            Log.e(TAG, "No input surface for VirtualDisplay")
            return
        }

        val existing = virtualDisplay
        if (existing != null) {
            // Update existing VirtualDisplay — avoids SecurityException on Android 14+
            existing.resize(encoder.width, encoder.height, resources.displayMetrics.densityDpi)
            existing.setSurface(surface)
            Log.i(TAG, "VirtualDisplay resized: ${encoder.width}x${encoder.height}")
        } else {
            virtualDisplay = mediaProjection?.createVirtualDisplay(
                "BetterCast",
                encoder.width,
                encoder.height,
                resources.displayMetrics.densityDpi,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                surface,
                null,
                null
            )
            Log.i(TAG, "VirtualDisplay created: ${encoder.width}x${encoder.height}")
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        releaseVirtualDisplay()
        mediaProjection?.stop()
        mediaProjection = null

        // Clear static references
        instance = null
        projectionResultData = null
        videoEncoder = null
        projectionResultCode = 0

        Log.i(TAG, "Service destroyed")
    }

    private fun releaseVirtualDisplay() {
        virtualDisplay?.release()
        virtualDisplay = null
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Screen Capture",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "BetterCast screen capture notification"
            }
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        return builder
            .setContentTitle("BetterCast")
            .setContentText("Casting your screen")
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setOngoing(true)
            .build()
    }
}
