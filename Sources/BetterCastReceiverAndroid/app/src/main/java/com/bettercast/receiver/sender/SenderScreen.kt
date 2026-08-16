package com.bettercast.receiver.sender

import android.app.Activity
import android.content.pm.ActivityInfo
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Cable
import androidx.compose.material.icons.filled.PlayCircle
import androidx.compose.material.icons.filled.ScreenShare
import androidx.compose.material.icons.filled.WarningAmber
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.bettercast.receiver.ui.components.BCHeader
import com.bettercast.receiver.ui.components.GlassButton
import com.bettercast.receiver.ui.components.GlassCard
import com.bettercast.receiver.ui.components.GradientButton
import com.bettercast.receiver.ui.components.IconTile
import com.bettercast.receiver.ui.components.StepCard
import com.bettercast.receiver.ui.theme.BC
import com.bettercast.receiver.ui.theme.BCType

@Composable
fun SenderScreen(viewModel: SenderViewModel) {
    val state by viewModel.state.collectAsState()
    val statusMessage by viewModel.statusMessage.collectAsState()

    // Idle and waiting are read-the-screen states, so they stay upright. Once capture is
    // running the phone is the source, and its rotation is the thing being streamed —
    // pinning it portrait there would stop the Mac ever seeing a landscape frame.
    val context = LocalContext.current
    LaunchedEffect(state) {
        (context as? Activity)?.requestedOrientation = when (state) {
            SenderState.CONNECTED -> ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
            else -> ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
        }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(BC.background)
    ) {
        when (state) {
            SenderState.IDLE -> IdleView(
                statusMessage = statusMessage,
                onStartCasting = { viewModel.startSending() }
            )

            SenderState.WAITING -> WaitingView(
                statusMessage = statusMessage,
                port = viewModel.tcpSender.listeningPort,
                onStop = { viewModel.stopSending() }
            )

            SenderState.CONNECTED -> ConnectedView(
                statusMessage = statusMessage,
                onStop = { viewModel.stopSending() }
            )

            SenderState.ERROR -> ErrorView(
                statusMessage = statusMessage,
                onRetry = { viewModel.retry() }
            )
        }
    }
}

@Composable
private fun SenderScaffold(content: @Composable () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(BC.background)
            .verticalScroll(rememberScrollState())
            .padding(horizontal = BC.screenPadding)
    ) {
        BCHeader(Icons.Filled.PlayCircle)
        Text("Send", style = BCType.display, color = BC.onSurface)
        Spacer(Modifier.height(8.dp))
        Text(
            "Stream this phone's screen to a Mac running BetterCast.",
            style = BCType.bodySmall,
            color = BC.onSurfaceVariant
        )
        Spacer(Modifier.height(20.dp))
        content()
        Spacer(Modifier.height(BC.navClearance))
    }
}

@Composable
private fun IdleView(statusMessage: String, onStartCasting: () -> Unit) {
    SenderScaffold {
        StepCard(
            icon = Icons.Filled.ScreenShare,
            iconColor = BC.primaryDim,
            title = "Cast this screen",
            description = "Android will ask permission to record the screen. Everything on " +
                "this display, including notifications, goes to the Mac.",
            actionText = "Start Casting",
            onAction = onStartCasting
        )

        if (statusMessage.isNotBlank()) {
            Spacer(Modifier.height(14.dp))
            Text(statusMessage, style = BCType.bodySmall, color = BC.onSurfaceVariant)
        }
    }
}

@Composable
private fun WaitingView(statusMessage: String, port: Int, onStop: () -> Unit) {
    SenderScaffold {
        GlassCard(modifier = Modifier.fillMaxWidth()) {
            Column(modifier = Modifier.padding(16.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(18.dp),
                        color = BC.primary,
                        strokeWidth = 2.dp
                    )
                    Spacer(Modifier.width(12.dp))
                    Text(statusMessage, style = BCType.bodySmall, color = BC.onSurface)
                }
            }
        }

        if (port > 0) {
            Spacer(Modifier.height(16.dp))
            StepCard(
                icon = Icons.Filled.Cable,
                iconColor = BC.secondaryDim,
                title = "Finish on the Mac",
                description = "Capture is running. The Mac reaches it over the USB bridge.",
                extra = {
                    Text("RUN ON THE MAC", style = BCType.badge, color = BC.onSurfaceVariant)
                    Spacer(Modifier.height(6.dp))
                    Text(
                        "adb forward tcp:$port tcp:$port",
                        style = BCType.rowTitle,
                        color = BC.primaryDim
                    )
                    Spacer(Modifier.height(10.dp))
                    Text(
                        "Then point BetterCast Receiver at localhost:$port.",
                        style = BCType.bodySmall,
                        color = BC.onSurfaceVariant
                    )
                }
            )
        }

        Spacer(Modifier.height(16.dp))
        GlassButton("Stop", onClick = onStop, tint = BC.danger)
    }
}

@Composable
private fun ConnectedView(statusMessage: String, onStop: () -> Unit) {
    SenderScaffold {
        GlassCard(modifier = Modifier.fillMaxWidth()) {
            Column(modifier = Modifier.padding(16.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(
                        modifier = Modifier
                            .size(10.dp)
                            .background(BC.success, CircleShape)
                    )
                    Spacer(Modifier.width(12.dp))
                    Text("Casting", style = BCType.cardTitle, color = BC.onSurface)
                }
                Spacer(Modifier.height(8.dp))
                Text(statusMessage, style = BCType.bodySmall, color = BC.onSurfaceVariant)
            }
        }

        Spacer(Modifier.height(16.dp))
        GlassButton("Stop Casting", onClick = onStop, tint = BC.danger)
    }
}

@Composable
private fun ErrorView(statusMessage: String, onRetry: () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(BC.background)
            .padding(BC.screenPadding),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        GlassCard(modifier = Modifier.fillMaxWidth()) {
            Column(modifier = Modifier.padding(20.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    IconTile(Icons.Filled.WarningAmber, BC.danger)
                    Spacer(Modifier.width(14.dp))
                    Text("Casting failed", style = BCType.cardTitle, color = BC.onSurface)
                }
                Spacer(Modifier.height(12.dp))
                Text(
                    statusMessage,
                    style = BCType.bodySmall,
                    color = BC.onSurfaceVariant,
                    textAlign = TextAlign.Start
                )
                Spacer(Modifier.height(18.dp))
                GradientButton("Try Again", onClick = onRetry)
            }
        }
    }
}
