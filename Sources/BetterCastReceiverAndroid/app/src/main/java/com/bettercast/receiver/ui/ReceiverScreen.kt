package com.bettercast.receiver.ui

import android.view.SurfaceHolder
import android.view.SurfaceView
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import android.Manifest
import android.app.Activity
import android.content.pm.ActivityInfo
import androidx.compose.ui.platform.LocalContext
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.DesktopMac
import androidx.compose.material.icons.filled.PlayCircle
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.WarningAmber
import androidx.compose.material.icons.filled.WifiTethering
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
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
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.bettercast.receiver.R
import com.bettercast.receiver.input.TouchHandler
import com.bettercast.receiver.ui.components.BCBadge
import com.bettercast.receiver.ui.components.DisclosureRow
import com.bettercast.receiver.ui.components.RowDivider
import com.bettercast.receiver.ui.components.BCHeader
import com.bettercast.receiver.ui.components.GlassButton
import com.bettercast.receiver.ui.components.GlassCard
import com.bettercast.receiver.ui.components.GradientButton
import com.bettercast.receiver.ui.components.IconTile
import com.bettercast.receiver.ui.components.StepCard
import com.bettercast.receiver.ui.theme.BC
import com.bettercast.receiver.ui.theme.BCType
import com.bettercast.receiver.viewmodel.ReceiverState
import com.bettercast.receiver.viewmodel.ReceiverViewModel
import kotlinx.coroutines.delay

@Composable
fun ReceiverScreen(
    viewModel: ReceiverViewModel,
    navVisible: Boolean = true,
    onToggleNav: () -> Unit = {},
    onShowSetup: () -> Unit = {}
) {
    val state by viewModel.state.collectAsState()

    // Portrait while waiting — the setup text, hotspot details and QR all read
    // better upright, and the QR gets far more room. Landscape only once a stream
    // is live, which is when the phone is actually acting as a display.
    val context = LocalContext.current
    LaunchedEffect(state) {
        (context as? Activity)?.requestedOrientation = when (state) {
            ReceiverState.CONNECTED -> ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
            else -> ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
        }
    }
    val statusMessage by viewModel.statusMessage.collectAsState()
    val deviceIp by viewModel.deviceIp.collectAsState()

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(BC.background)
    ) {
        when (state) {
            ReceiverState.WAITING -> {
                WaitingView(
                    statusMessage = statusMessage,
                    deviceIp = deviceIp,
                    port = viewModel.tcpServer.listeningPort,
                    viewModel = viewModel
                )
            }

            ReceiverState.RECONNECTING -> {
                ReconnectingView(
                    statusMessage = statusMessage,
                    onBack = { viewModel.backToDevices() }
                )
            }

            ReceiverState.CONNECTED -> {
                ConnectedView(
                    viewModel = viewModel,
                    statusMessage = statusMessage,
                    navVisible = navVisible,
                    onToggleNav = onToggleNav,
                    onShowSetup = onShowSetup
                )
            }

            ReceiverState.ERROR -> {
                ErrorView(
                    statusMessage = statusMessage,
                    onRetry = { viewModel.retry() }
                )
            }
        }
    }
}

@Composable
private fun WaitingView(
    statusMessage: String,
    deviceIp: String?,
    port: Int,
    viewModel: ReceiverViewModel
) {
    val hotspot by viewModel.hotspot.collectAsState()
    val hotspotError by viewModel.hotspotError.collectAsState()
    val senders by viewModel.discoveredSenders.collectAsState()
    val inviting by viewModel.invitingSender.collectAsState()
    val inviteError by viewModel.inviteError.collectAsState()

    // startLocalOnlyHotspot is gated on nearby-devices from Android 13, and on fine
    // location before that. Ask for whichever applies, then start on the grant.
    val permission = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        Manifest.permission.NEARBY_WIFI_DEVICES
    } else {
        Manifest.permission.ACCESS_FINE_LOCATION
    }
    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted ->
        if (granted) viewModel.startHotspot()
    }

    // Scrolls, and starts at the top rather than centring. Centred content that
    // outgrows the screen is clipped at both ends with no way to reach it — which
    // is exactly what happened once the hotspot QR joined this column.
    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = BC.screenPadding)
    ) {
        BCHeader(Icons.Filled.PlayCircle)

        Text(stringResource(R.string.waiting_title), style = BCType.display, color = BC.onSurface)
        Spacer(Modifier.height(8.dp))
        Text(
            stringResource(R.string.waiting_subtitle),
            style = BCType.bodySmall,
            color = BC.onSurfaceVariant
        )

        Spacer(Modifier.height(20.dp))

        // Status card: the live state of the receiver, and the address to type if
        // discovery does not find it.
        GlassCard(modifier = Modifier.fillMaxWidth()) {
            Column(modifier = Modifier.padding(16.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    PulsingDot(BC.accentGold)
                    Spacer(Modifier.width(10.dp))
                    Text(statusMessage, style = BCType.bodySmall, color = BC.onSurface)
                }

                if (deviceIp != null && port > 0) {
                    Spacer(Modifier.height(14.dp))
                    Text(stringResource(R.string.label_address), style = BCType.badge, color = BC.onSurfaceVariant)
                    Spacer(Modifier.height(4.dp))
                    Text(
                        "$deviceIp:$port",
                        style = BCType.title,
                        color = BC.primaryDim
                    )
                }
            }
        }

        Spacer(Modifier.height(16.dp))

        // Macs advertising on this network. Tapping one asks it to stream here, which
        // saves walking over to the Mac to start the session from that end.
        if (senders.isNotEmpty()) {
            Text(stringResource(R.string.label_macs_on_network), style = BCType.badge, color = BC.onSurfaceVariant)
            Spacer(Modifier.height(8.dp))
            GlassCard(modifier = Modifier.fillMaxWidth()) {
                senders.forEachIndexed { index, sender ->
                    if (index > 0) RowDivider()
                    DisclosureRow(
                        icon = Icons.Filled.DesktopMac,
                        iconColor = BC.primaryDim,
                        title = sender.name,
                        subtitle = if (inviting == sender.name) stringResource(R.string.inviting)
                                   else "${sender.host}:${sender.port}",
                        onClick = { viewModel.inviteSender(sender) }
                    )
                }
            }
            inviteError?.let { error ->
                Spacer(Modifier.height(8.dp))
                Text(error, style = BCType.bodySmall, color = BC.accentOrange)
            }
            Spacer(Modifier.height(16.dp))
        }

        // Hotspot — the only way to pair when there is no shared network at all.
        if (hotspot == null) {
            StepCard(
                icon = Icons.Filled.WifiTethering,
                iconColor = BC.accentGold,
                title = stringResource(R.string.hotspot_prompt_title),
                description = stringResource(R.string.hotspot_prompt_desc),
                actionText = stringResource(R.string.action_create_hotspot),
                onAction = { permissionLauncher.launch(permission) }
            )
        } else {
            GlassCard(modifier = Modifier.fillMaxWidth()) {
                Column(
                    modifier = Modifier.padding(16.dp),
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Text(stringResource(R.string.hotspot_active), style = BCType.cardTitle, color = BC.onSurface)
                        Spacer(Modifier.weight(1f))
                        BCBadge(stringResource(R.string.badge_scan_me), BC.success)
                    }

                    Spacer(Modifier.height(14.dp))

                    // The Mac reads this with its camera. Credentials are regenerated
                    // on every start, so typing them each session is not workable.
                    WifiQrImage(
                        ssid = hotspot!!.ssid,
                        passphrase = hotspot!!.passphrase,
                        modifier = Modifier.size(240.dp)
                    )

                    Spacer(Modifier.height(14.dp))
                    Text(
                        stringResource(R.string.hotspot_scan_hint),
                        style = BCType.bodySmall,
                        color = BC.onSurfaceVariant,
                        textAlign = TextAlign.Center
                    )

                    Spacer(Modifier.height(14.dp))
                    CredentialRow(stringResource(R.string.label_network), hotspot!!.ssid)
                    Spacer(Modifier.height(4.dp))
                    CredentialRow(stringResource(R.string.label_password), hotspot!!.passphrase)

                    Spacer(Modifier.height(10.dp))
                    Text(
                        stringResource(R.string.hotspot_no_internet),
                        style = BCType.bodySmall,
                        color = BC.onSurfaceVariant.copy(alpha = 0.7f),
                        textAlign = TextAlign.Center
                    )

                    Spacer(Modifier.height(14.dp))
                    GlassButton(
                        stringResource(R.string.action_stop_hotspot),
                        onClick = { viewModel.stopHotspot() },
                        tint = BC.danger
                    )
                }
            }
        }

        hotspotError?.let { error ->
            Spacer(Modifier.height(12.dp))
            Text(
                text = error,
                style = BCType.bodySmall,
                color = BC.accentOrange,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth()
            )
        }

        Spacer(Modifier.height(BC.navClearance))
    }
}

@Composable
private fun CredentialRow(label: String, value: String) {
    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(label.uppercase(), style = BCType.badge, color = BC.onSurfaceVariant)
        Spacer(Modifier.weight(1f))
        Text(value, style = BCType.body, color = BC.onSurface)
    }
}

/** Classic arrow pointer, outlined so it stays visible over light and dark content. */
@Composable
private fun VirtualCursor(modifier: Modifier = Modifier) {
    Canvas(modifier = modifier.size(22.dp)) {
        val w = size.width
        val h = size.height
        val arrow = Path().apply {
            moveTo(0f, 0f)
            lineTo(0f, h * 0.76f)
            lineTo(w * 0.25f, h * 0.57f)
            lineTo(w * 0.43f, h * 0.97f)
            lineTo(w * 0.61f, h * 0.89f)
            lineTo(w * 0.43f, h * 0.51f)
            lineTo(w * 0.72f, h * 0.49f)
            close()
        }
        drawPath(arrow, Color.Black.copy(alpha = 0.65f), style = Stroke(width = 4f))
        drawPath(arrow, Color.White)
    }
}

/** Slow breathing dot — the iOS onboarding uses the same idle signal. */
@Composable
private fun PulsingDot(color: Color) {
    val transition = rememberInfiniteTransition(label = "pulse")
    val alpha by transition.animateFloat(
        initialValue = 0.35f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(1100, easing = LinearEasing),
            repeatMode = RepeatMode.Reverse
        ),
        label = "pulseAlpha"
    )
    Box(
        modifier = Modifier
            .size(9.dp)
            .background(color.copy(alpha = alpha), CircleShape)
    )
}

@Composable
private fun ReconnectingView(statusMessage: String, onBack: () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(BC.screenPadding),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        CircularProgressIndicator(
            modifier = Modifier.size(40.dp),
            color = BC.primary,
            strokeWidth = 3.dp
        )

        Spacer(modifier = Modifier.height(20.dp))

        Text(statusMessage, style = BCType.cardTitle, color = BC.onSurface, textAlign = TextAlign.Center)

        Spacer(modifier = Modifier.height(8.dp))

        Text(
            stringResource(R.string.reconnecting_desc),
            style = BCType.bodySmall,
            color = BC.onSurfaceVariant,
            textAlign = TextAlign.Center
        )

        Spacer(modifier = Modifier.height(24.dp))

        // Escape hatch. This screen gives up on its own after a few seconds, but waiting
        // out a timer is a poor experience when you already know the sender is not coming.
        GlassButton(
            stringResource(R.string.action_back_to_devices),
            onClick = onBack,
            modifier = Modifier.fillMaxWidth(0.7f)
        )
    }
}

@Composable
private fun ConnectedView(
    viewModel: ReceiverViewModel,
    statusMessage: String,
    navVisible: Boolean,
    onToggleNav: () -> Unit,
    onShowSetup: () -> Unit
) {
    var menuOpen by remember { mutableStateOf(false) }
    var controlsHidden by remember { mutableStateOf(false) }
    val aspectFill by viewModel.settings.aspectFill.collectAsState()
    val cursorMode by viewModel.settings.cursorMode.collectAsState()
    var cursorPos by remember { mutableStateOf(0.5f to 0.5f) }
    // The factory runs once, so keep a handle to push later setting changes into it.
    val touchHandlerRef = remember { mutableStateOf<TouchHandler?>(null) }
    var showStatus by remember { mutableStateOf(true) }
    // Bumped by the three-finger reveal, which re-runs the auto-hide timer.
    var revealTick by remember { mutableStateOf(0) }

    val videoSize by viewModel.videoDecoder.videoSize.collectAsState()

    LaunchedEffect(revealTick) {
        showStatus = true
        delay(3000)
        showStatus = false
    }

    BoxWithConstraints(
        modifier = Modifier
            .fillMaxSize()
            .background(BC.background)
            .clipToBounds()
    ) {
        // Shape the surface to the stream, rather than letting MediaCodec stretch the
        // picture to whatever shape the phone is. Fit letterboxes; fill crops the
        // overflowing edges, which is why the surface is allowed to exceed the box.
        val ratio = videoSize?.let { (w, h) ->
            if (w > 0 && h > 0) w.toFloat() / h.toFloat() else null
        }
        val videoSizeDp = if (ratio == null) {
            maxWidth to maxHeight
        } else {
            val boxRatio = maxWidth / maxHeight
            val matchWidth = if (aspectFill) ratio < boxRatio else ratio > boxRatio
            if (matchWidth) maxWidth to (maxWidth / ratio) else (maxHeight * ratio) to maxHeight
        }
        val (videoW, videoH) = videoSizeDp
        val videoModifier = Modifier.size(videoW, videoH)

        AndroidView(
            factory = { context ->
                SurfaceView(context).apply {
                    // Touches map to the surface, and the surface is now exactly the
                    // video rect, so the normalised coordinates are correct in both
                    // fit and fill without any extra letterbox arithmetic.
                    val touchHandler = TouchHandler(this) { event ->
                        viewModel.sendInputEvent(event)
                    }
                    touchHandler.onThreeFingerTap = {
                        controlsHidden = false
                        revealTick++
                    }
                    touchHandler.onCursorMoved = { x, y -> cursorPos = x to y }
                    touchHandler.cursorMode = cursorMode
                    touchHandlerRef.value = touchHandler

                    holder.addCallback(object : SurfaceHolder.Callback {
                        override fun surfaceCreated(holder: SurfaceHolder) {
                            viewModel.videoDecoder.setSurface(holder.surface)
                        }

                        override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
                            touchHandler.updateVideoRect(0f, 0f, width.toFloat(), height.toFloat())
                        }

                        override fun surfaceDestroyed(holder: SurfaceHolder) {
                            viewModel.videoDecoder.setSurface(null)
                        }
                    })
                }
            },
            update = { touchHandlerRef.value?.cursorMode = cursorMode },
            modifier = videoModifier.align(Alignment.Center)
        )

        // Trackpad pointer. Drawn over the video rather than moved on the Mac, because
        // the Mac's own cursor is only visible once it has been told where to go — and
        // in trackpad mode the finger is nowhere near the target.
        if (cursorMode) {
            Box(modifier = videoModifier.align(Alignment.Center)) {
                VirtualCursor(
                    modifier = Modifier.offset(
                        x = videoW * cursorPos.first - 2.dp,
                        y = videoH * cursorPos.second - 2.dp
                    )
                )
            }
        }

        // Status overlay
        AnimatedVisibility(
            visible = showStatus,
            enter = fadeIn(),
            exit = fadeOut(),
            modifier = Modifier.align(Alignment.TopCenter)
        ) {
            Box(
                modifier = Modifier
                    .padding(top = 16.dp)
                    .background(
                        color = Color(0x99000000),
                        shape = RoundedCornerShape(8.dp)
                    )
                    .padding(horizontal = 16.dp, vertical = 8.dp)
            ) {
                Text(
                    text = statusMessage,
                    fontSize = 14.sp,
                    color = Color.White
                )
            }
        }

        // Settings button, mirroring the iOS receiver's floating gear. It stays put
        // rather than fading with the status pill: every touch on the video belongs
        // to the Mac, so a control that disappears on a timer would be unreachable.
        if (!controlsHidden) {
            Box(
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .padding(12.dp)
            ) {
                IconButton(
                    onClick = { menuOpen = true },
                    modifier = Modifier
                        .size(40.dp)
                        .background(Color(0x66000000), CircleShape)
                ) {
                    Icon(
                        imageVector = Icons.Default.Settings,
                        contentDescription = stringResource(R.string.cd_display_options),
                        tint = Color.White.copy(alpha = 0.85f)
                    )
                }

                DropdownMenu(
                    expanded = menuOpen,
                    onDismissRequest = { menuOpen = false }
                ) {
                    DropdownMenuItem(
                        // Labelled by what the tap does. iOS labels these by current
                        // state instead, but it draws a checkmark next to them; a bare
                        // menu row with no checkmark has to name the action.
                        text = {
                            Text(stringResource(
                                if (aspectFill) R.string.menu_fit_screen else R.string.menu_fill_screen
                            ))
                        },
                        onClick = { viewModel.settings.setAspectFill(!aspectFill); menuOpen = false }
                    )
                    DropdownMenuItem(
                        text = {
                            Text(stringResource(
                                if (cursorMode) R.string.menu_touch_mode else R.string.menu_cursor_mode
                            ))
                        },
                        onClick = { viewModel.settings.setCursorMode(!cursorMode); menuOpen = false }
                    )
                    DropdownMenuItem(
                        text = {
                            Text(stringResource(
                                if (navVisible) R.string.menu_hide_nav else R.string.menu_show_nav
                            ))
                        },
                        onClick = { onToggleNav(); menuOpen = false }
                    )
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.help_setup_guide)) },
                        onClick = { menuOpen = false; onShowSetup() }
                    )
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.menu_hide_controls)) },
                        onClick = { menuOpen = false; controlsHidden = true }
                    )
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.action_disconnect), color = Color(0xFFFF5252)) },
                        onClick = { menuOpen = false; viewModel.disconnect() }
                    )
                }
            }
        }
    }
}

@Composable
private fun ErrorView(
    statusMessage: String,
    onRetry: () -> Unit
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(BC.screenPadding),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        GlassCard(modifier = Modifier.fillMaxWidth()) {
            Column(modifier = Modifier.padding(20.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    IconTile(Icons.Filled.WarningAmber, BC.danger)
                    Spacer(Modifier.width(14.dp))
                    Text(stringResource(R.string.error_title), style = BCType.cardTitle, color = BC.onSurface)
                }

                Spacer(Modifier.height(12.dp))

                Text(statusMessage, style = BCType.bodySmall, color = BC.onSurfaceVariant)

                Spacer(Modifier.height(18.dp))

                GradientButton(stringResource(R.string.action_try_again), onClick = onRetry)
            }
        }
    }
}
