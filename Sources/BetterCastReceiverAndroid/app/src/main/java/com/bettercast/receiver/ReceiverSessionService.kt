package com.bettercast.receiver

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.bettercast.receiver.viewmodel.ReceiverState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch

/**
 * Keeps a live stream running after the app is closed.
 *
 * Swiping BetterCast out of Recents destroys the activity, and with nothing else in the
 * process Android is free to kill it — which closed the socket and made the Mac take its
 * virtual display away mid-session. While this service is in the foreground the process
 * stays, BetterCastApp keeps the receiver alive, and the notification gives the user a
 * one-tap way to end the session without reopening the app.
 *
 * It runs only while there is a stream (connected, or briefly reconnecting during a
 * transport handover). The moment the session ends it stops itself, and if no screen is
 * open it releases the receiver too, so a closed app does not linger on the network.
 */
class ReceiverSessionService : Service() {

    companion object {
        private const val TAG = "ReceiverSessionService"
        private const val NOTIFICATION_ID = 1002
        private const val CHANNEL_ID = "receiver_session"
        private const val ACTION_DISCONNECT = "com.bettercast.receiver.action.DISCONNECT"

        /**
         * Start or refresh the service. Called while the activity is visible: Android 12+
         * refuses to start a foreground service from the background, and if it does, the
         * stream simply keeps today's behaviour rather than crashing the app.
         */
        fun start(context: Context) {
            try {
                ContextCompat.startForegroundService(context, Intent(context, ReceiverSessionService::class.java))
            } catch (e: Exception) {
                Log.w(TAG, "Could not start the session service", e)
            }
        }
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var watchJob: Job? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val app = application as BetterCastApp

        if (intent?.action == ACTION_DISCONNECT) {
            // Only act on a session this service is actually watching. A stale notification
            // tapped after the process was recycled must not spin up a fresh receiver just
            // to disconnect it.
            if (watchJob != null) app.receiverViewModel.disconnect() else stopSelf()
            return START_NOT_STICKY
        }

        createNotificationChannel()
        val vm = app.receiverViewModel
        ServiceCompat.startForeground(
            this,
            NOTIFICATION_ID,
            buildNotification(vm.connectedSenderName.value),
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE else 0
        )

        if (watchJob == null) {
            watchJob = scope.launch {
                combine(vm.state, vm.connectedSenderName) { state, name -> state to name }
                    .collect { (state, name) ->
                        when (state) {
                            ReceiverState.CONNECTED, ReceiverState.RECONNECTING -> {
                                getSystemService(NotificationManager::class.java)
                                    ?.notify(NOTIFICATION_ID, buildNotification(name))
                            }
                            else -> endSession(app)
                        }
                    }
            }
        }
        // A killed process takes the stream with it; there is nothing to come back to.
        return START_NOT_STICKY
    }

    private fun endSession(app: BetterCastApp) {
        watchJob?.cancel()
        watchJob = null
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
        if (!app.activityAlive) {
            Log.i(TAG, "Stream ended with no screen open — releasing the receiver")
            app.releaseReceiver()
        }
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                getString(R.string.notif_channel_session),
                NotificationManager.IMPORTANCE_LOW
            )
            getSystemService(NotificationManager::class.java)?.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(senderName: String?): Notification {
        val open = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val disconnect = PendingIntent.getService(
            this, 1,
            Intent(this, ReceiverSessionService::class.java).setAction(ACTION_DISCONNECT),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val title = senderName?.let { getString(R.string.notif_session_title, it) }
            ?: getString(R.string.notif_session_title_generic)

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(getString(R.string.notif_session_text))
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentIntent(open)
            .addAction(0, getString(R.string.action_disconnect), disconnect)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }
}
