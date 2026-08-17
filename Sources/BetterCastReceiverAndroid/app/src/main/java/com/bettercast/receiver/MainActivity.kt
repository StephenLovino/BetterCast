package com.bettercast.receiver

import android.app.Activity
import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.ViewModelProvider
import com.bettercast.receiver.sender.SenderScreen
import com.bettercast.receiver.sender.SenderState
import com.bettercast.receiver.sender.SenderViewModel
import androidx.compose.runtime.saveable.rememberSaveable
import com.bettercast.receiver.ui.DonatePromptDialog
import com.bettercast.receiver.ui.ReceiverShell
import com.bettercast.receiver.ui.theme.BC
import com.bettercast.receiver.ui.theme.BetterCastReceiverTheme
import com.bettercast.receiver.viewmodel.ReceiverState
import com.bettercast.receiver.viewmodel.ReceiverViewModel

enum class AppMode { RECEIVER, SENDER }

class MainActivity : ComponentActivity() {

    private lateinit var receiverViewModel: ReceiverViewModel
    private lateinit var senderViewModel: SenderViewModel

    private val projectionLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result ->
        if (result.resultCode == Activity.RESULT_OK && result.data != null) {
            senderViewModel.onProjectionGranted(result.resultCode, result.data!!)
        } else {
            senderViewModel.onProjectionDenied()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Keep screen on
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        // Draw edge to edge, then let Compose inset the parts that need it. The app
        // used to hide the system bars from launch and pad nothing, so the very top
        // row of the UI sat underneath the status bar and camera cutout.
        WindowCompat.setDecorFitsSystemWindows(window, false)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            // Reassign rather than mutate in place — the setter is what makes the
            // window manager re-lay-out with the new cutout mode.
            window.attributes = window.attributes.apply {
                layoutInDisplayCutoutMode =
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
            }
        }
        applyImmersive(false)

        receiverViewModel = ViewModelProvider(this)[ReceiverViewModel::class.java]
        senderViewModel = ViewModelProvider(this)[SenderViewModel::class.java]

        setContent {
            // Theme follows the persisted preference, so Settings can switch it live.
            val themeMode by receiverViewModel.settings.themeMode.collectAsState()
            BetterCastReceiverTheme(themeMode = themeMode) {
                val requestProjection by senderViewModel.requestProjection.collectAsState()

                // Launch MediaProjection permission when requested by SenderViewModel
                LaunchedEffect(requestProjection) {
                    if (requestProjection) {
                        val mpManager = getSystemService(MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
                        projectionLauncher.launch(mpManager.createScreenCaptureIntent())
                    }
                }

                AppContent(
                    activity = this@MainActivity,
                    receiverViewModel = receiverViewModel,
                    senderViewModel = senderViewModel
                )
            }
        }
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        senderViewModel.onOrientationChanged()
    }

    /**
     * Hide the system bars only while the phone is actually showing a stream.
     *
     * Full-screen is right for video and wrong for everything else: with the bars
     * hidden their insets report zero, so setup screens lose the padding that keeps
     * them clear of the status bar and the gesture strip.
     */
    fun applyImmersive(immersive: Boolean) {
        isImmersive = immersive
        val controller = WindowInsetsControllerCompat(window, window.decorView)
        if (immersive) {
            controller.hide(WindowInsetsCompat.Type.systemBars())
            controller.systemBarsBehavior =
                WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        } else {
            controller.show(WindowInsetsCompat.Type.systemBars())
        }
    }

    private var isImmersive = false

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        // Transient bars come back on their own after an interaction; re-apply so a
        // stream returns to full screen, but never yank the bars off a setup screen.
        if (hasFocus && isImmersive) applyImmersive(true)
    }
}

@Composable
fun AppContent(
    activity: Activity,
    receiverViewModel: ReceiverViewModel,
    senderViewModel: SenderViewModel
) {
    var mode by remember { mutableStateOf(AppMode.RECEIVER) }

    val receiverState by receiverViewModel.state.collectAsState()
    val senderState by senderViewModel.state.collectAsState()

    // Decided once per process, not per recomposition, so rotating the phone or
    // switching modes does not bring the nudge back mid-session.
    var showDonatePrompt by rememberSaveable { mutableStateOf(false) }
    var donateDecided by rememberSaveable { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        if (!donateDecided) {
            donateDecided = true
            showDonatePrompt = receiverViewModel.settings.shouldShowDonatePromptOnLaunch()
        }
    }
    if (showDonatePrompt) {
        DonatePromptDialog(
            onLater = { showDonatePrompt = false },
            onAlreadyDonated = {
                receiverViewModel.settings.silenceDonatePrompt()
                showDonatePrompt = false
            }
        )
    }

    // Hide mode toggle when actively connected/casting
    val showModeToggle = when (mode) {
        AppMode.RECEIVER -> receiverState != ReceiverState.CONNECTED
        AppMode.SENDER -> senderState == SenderState.IDLE || senderState == SenderState.ERROR
    }

    // Video is the one thing that should reach the edges of the panel. Every other
    // screen keeps clear of the status bar, the camera cutout and the gesture strip.
    val fullBleed = mode == AppMode.RECEIVER && receiverState == ReceiverState.CONNECTED
    LaunchedEffect(fullBleed) {
        (activity as? MainActivity)?.applyImmersive(fullBleed)
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(BC.background)
            .then(
                if (fullBleed) Modifier
                else Modifier.windowInsetsPadding(WindowInsets.safeDrawing)
            )
    ) {
        // Mode toggle bar
        if (showModeToggle) {
            ModeToggleBar(
                currentMode = mode,
                onModeChange = { newMode ->
                    if (newMode != mode) {
                        // Stop current mode before switching
                        when (mode) {
                            AppMode.RECEIVER -> receiverViewModel.stopReceiver()
                            AppMode.SENDER -> senderViewModel.stopSending()
                        }
                        mode = newMode
                        // Set orientation and start the new mode
                        when (newMode) {
                            AppMode.RECEIVER -> {
                                // Portrait while waiting; ReceiverScreen flips to
                                // landscape once a stream actually connects.
                                activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
                                receiverViewModel.retry()
                            }
                            AppMode.SENDER -> {
                                // Portrait, like the receiver's idle screen. UNSPECIFIED
                                // let the sensor swing it to landscape the moment the
                                // phone tilted, which is not what picking "Send" asks for.
                                // SenderScreen re-opens rotation once capture starts.
                                activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
                            }
                        }
                    }
                }
            )
        }

        // Content
        Box(modifier = Modifier.fillMaxSize()) {
            when (mode) {
                AppMode.RECEIVER -> ReceiverShell(viewModel = receiverViewModel)
                AppMode.SENDER -> SenderScreen(viewModel = senderViewModel)
            }
        }
    }
}

/**
 * Segmented control in the style of the iOS app: one recessed track, the selected
 * half raised out of it. Replaces two competing filled buttons, which read as the
 * loudest thing on screen when they are really just a mode switch.
 */
@Composable
fun ModeToggleBar(currentMode: AppMode, onModeChange: (AppMode) -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = BC.screenPadding, vertical = 10.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(BC.segmentTrack)
            .padding(3.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        ModeButton(
            text = androidx.compose.ui.res.stringResource(R.string.mode_receive),
            isSelected = currentMode == AppMode.RECEIVER,
            onClick = { onModeChange(AppMode.RECEIVER) },
            modifier = Modifier.weight(1f)
        )
        ModeButton(
            text = androidx.compose.ui.res.stringResource(R.string.mode_send),
            isSelected = currentMode == AppMode.SENDER,
            onClick = { onModeChange(AppMode.SENDER) },
            modifier = Modifier.weight(1f)
        )
    }
}

@Composable
fun ModeButton(
    text: String,
    isSelected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier
) {
    Box(
        modifier = modifier
            .height(34.dp)
            .clip(RoundedCornerShape(9.dp))
            .background(if (isSelected) BC.segmentThumb else Color.Transparent)
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center
    ) {
        Text(
            text = text,
            fontSize = 14.sp,
            fontWeight = if (isSelected) FontWeight.SemiBold else FontWeight.Medium,
            color = if (isSelected) BC.onSurface else BC.onSurfaceVariant.copy(alpha = 0.7f)
        )
    }
}
