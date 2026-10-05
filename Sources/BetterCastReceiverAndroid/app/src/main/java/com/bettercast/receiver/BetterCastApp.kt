package com.bettercast.receiver

import android.app.Application
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import androidx.lifecycle.ViewModelStoreOwner
import com.bettercast.receiver.viewmodel.ReceiverViewModel

/**
 * Owns the receiver for the life of the process rather than the life of a screen.
 *
 * The connection, decoder and audio all live in ReceiverViewModel. Scoped to the
 * activity, swiping the app out of Recents destroyed the activity, cleared the view
 * model and closed the socket, so the Mac tore down its virtual display and threw every
 * window on it back onto the main screen. Held here instead, the session outlives the
 * activity while ReceiverSessionService keeps the process alive, and a reopened app
 * picks the same stream back up.
 */
class BetterCastApp : Application(), ViewModelStoreOwner {

    override val viewModelStore = ViewModelStore()

    /**
     * MainActivity instances currently alive. A count rather than a flag: when the system
     * recreates the activity, the new one can be created before the old one is destroyed.
     * The service only tears the receiver down when nothing is showing it.
     */
    private var liveActivities = 0
    val activityAlive: Boolean get() = liveActivities > 0

    fun activityCreated() { liveActivities++ }
    fun activityDestroyed() { if (liveActivities > 0) liveActivities-- }

    val receiverViewModel: ReceiverViewModel
        get() = ViewModelProvider(this, ViewModelProvider.AndroidViewModelFactory.getInstance(this))[ReceiverViewModel::class.java]

    /**
     * Stop the receiver and drop it, so the next screen starts from a fresh one.
     *
     * Used when the app is closed with no stream running: a process the system keeps
     * cached would otherwise go on advertising itself and holding port 51820 with no UI.
     */
    fun releaseReceiver() {
        viewModelStore.clear()
    }
}
