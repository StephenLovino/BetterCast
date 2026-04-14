package com.bettercast.receiver

import android.app.Activity
import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.media.projection.MediaProjectionManager
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
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
import com.bettercast.receiver.ui.ReceiverScreen
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

        // Immersive fullscreen
        WindowCompat.setDecorFitsSystemWindows(window, false)
        val controller = WindowInsetsControllerCompat(window, window.decorView)
        controller.hide(WindowInsetsCompat.Type.systemBars())
        controller.systemBarsBehavior =
            WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE

        receiverViewModel = ViewModelProvider(this)[ReceiverViewModel::class.java]
        senderViewModel = ViewModelProvider(this)[SenderViewModel::class.java]

        setContent {
            BetterCastReceiverTheme {
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

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) {
            val controller = WindowInsetsControllerCompat(window, window.decorView)
            controller.hide(WindowInsetsCompat.Type.systemBars())
            controller.systemBarsBehavior =
                WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
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

    // Hide mode toggle when actively connected/casting
    val showModeToggle = when (mode) {
        AppMode.RECEIVER -> receiverState != ReceiverState.CONNECTED
        AppMode.SENDER -> senderState == SenderState.IDLE || senderState == SenderState.ERROR
    }

    Column(modifier = Modifier.fillMaxSize()) {
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
                                activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
                                receiverViewModel.retry()
                            }
                            AppMode.SENDER -> {
                                activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
                            }
                        }
                    }
                }
            )
        }

        // Content
        Box(modifier = Modifier.fillMaxSize()) {
            when (mode) {
                AppMode.RECEIVER -> ReceiverScreen(viewModel = receiverViewModel)
                AppMode.SENDER -> SenderScreen(viewModel = senderViewModel)
            }
        }
    }
}

@Composable
fun ModeToggleBar(currentMode: AppMode, onModeChange: (AppMode) -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(Color(0xFF1A1A1A))
            .padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        ModeButton(
            text = "Receive",
            isSelected = currentMode == AppMode.RECEIVER,
            onClick = { onModeChange(AppMode.RECEIVER) },
            modifier = Modifier.weight(1f)
        )

        ModeButton(
            text = "Send",
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
    Button(
        onClick = onClick,
        colors = ButtonDefaults.buttonColors(
            containerColor = if (isSelected) Color(0xFF2196F3) else Color(0xFF333333)
        ),
        shape = RoundedCornerShape(8.dp),
        modifier = modifier.padding(horizontal = 4.dp)
    ) {
        Text(
            text = text,
            fontSize = 14.sp,
            fontWeight = if (isSelected) FontWeight.Bold else FontWeight.Normal,
            color = Color.White
        )
    }
}
