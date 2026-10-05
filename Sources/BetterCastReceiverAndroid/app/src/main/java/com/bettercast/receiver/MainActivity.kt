package com.bettercast.receiver

import android.app.Activity
import android.app.PictureInPictureParams
import android.content.pm.ActivityInfo
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Rect
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.util.Rational
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
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch
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

    companion object {
        private const val TAG = "MainActivity"
        // The system refuses PiP aspect ratios outside roughly 1:2.39 .. 2.39:1, so a
        // very wide Mac desktop is clamped rather than throwing on transition.
        // 0.419, not 0.4184: the ratio is passed on as a Rational in thousandths, which
        // truncates 0.4184 to 418/1000, just below the system's 1/2.39 floor.
        private const val MIN_PIP_RATIO = 0.419f
        private const val MAX_PIP_RATIO = 2.39f
    }

    private lateinit var receiverViewModel: ReceiverViewModel
    private lateinit var senderViewModel: SenderViewModel

    /** Some low-memory devices report PiP as unavailable; entering would throw. */
    private val supportsPip by lazy {
        packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)
    }

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

        // PiP parameters are published while the activity is on screen: the system reads
        // the aspect ratio and source rect when it animates the window out, and on 12+
        // only honours auto-enter if it was set during a resumed frame.
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                combine(
                    receiverViewModel.state,
                    receiverViewModel.videoDecoder.videoSize,
                    receiverViewModel.videoRect
                ) { state, size, rect -> Triple(state, size, rect) }
                    .collect { (state, size, rect) ->
                        if (state == ReceiverState.CONNECTED) {
                            applyPipParams(buildPipParams(size, rect))
                        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                            // No stream to shrink: leaving the app must not drop the user
                            // into an empty PiP window, so auto-enter goes back off.
                            applyPipParams(
                                PictureInPictureParams.Builder()
                                    .setAutoEnterEnabled(false)
                                    .build()
                            )
                        }
                    }
            }
        }

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

    // ---- picture in picture ------------------------------------------------

    /**
     * Move a live stream into a PiP window.
     *
     * Called from the in-stream menu, and on Android 11 and below from onUserLeaveHint
     * (12+ uses setAutoEnterEnabled instead, which animates from the video rect).
     * Returns false when there is nothing to shrink or the device refuses.
     */
    fun enterPip(): Boolean {
        if (!supportsPip || isInPictureInPictureMode) return false
        if (receiverViewModel.state.value != ReceiverState.CONNECTED) return false
        val params = buildPipParams(
            receiverViewModel.videoDecoder.videoSize.value,
            receiverViewModel.videoRect.value
        )
        return runCatching { enterPictureInPictureMode(params) }
            .onFailure { Log.w(TAG, "Could not enter picture-in-picture", it) }
            .getOrDefault(false)
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) return // auto-enter handles it
        if (receiverViewModel.state.value != ReceiverState.CONNECTED) return
        if (!receiverViewModel.settings.autoPipEnabled.value) return
        enterPip()
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        receiverViewModel.setInPictureInPicture(isInPictureInPictureMode)
        // Back to full screen: the stream is immersive again, but only if the stream is
        // still what the activity is showing.
        if (!isInPictureInPictureMode && isImmersive) applyImmersive(true)
    }

    private fun buildPipParams(
        videoSize: Pair<Int, Int>?,
        videoRect: Rect?
    ): PictureInPictureParams {
        val builder = PictureInPictureParams.Builder()
        // Sized from the decoded picture, not the window: this is what the system makes
        // the PiP window, so a 16:10 Mac desktop arrives 16:10 instead of being squashed
        // into the phone's own shape.
        videoSize?.let { (width, height) ->
            if (width > 0 && height > 0) {
                val ratio = (width.toFloat() / height.toFloat())
                    .coerceIn(MIN_PIP_RATIO, MAX_PIP_RATIO)
                builder.setAspectRatio(Rational((ratio * 1000).toInt(), 1000))
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setAutoEnterEnabled(receiverViewModel.settings.autoPipEnabled.value)
        }
        // Where the video sits on screen — the rect the shrink animation starts from.
        videoRect?.let { if (!it.isEmpty) builder.setSourceRectHint(it) }
        return builder.build()
    }

    private fun applyPipParams(params: PictureInPictureParams) {
        if (!supportsPip) return
        runCatching { setPictureInPictureParams(params) }
            .onFailure { Log.w(TAG, "Could not set picture-in-picture params", it) }
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
        // A PiP window has no system bars to hide, so the intent is recorded but nothing
        // is touched until the activity is full screen again.
        if (isInPictureInPictureMode) return
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
        if (hasFocus && isImmersive && !isInPictureInPictureMode) applyImmersive(true)
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

    // Hide mode toggle when actively connected/casting — and always in PiP, where the
    // window is far too small for it.
    val inPip by receiverViewModel.inPictureInPicture.collectAsState()
    val showModeToggle = !inPip && when (mode) {
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
